// Emoji + Kitty image rasterization, offloaded to a worker thread.
//
// The main thread never touches librsvg/cairo or does bulk pixel-format
// conversion; it only submits jobs and, when a result is ready, uploads the
// finished RGBA buffer to the GPU (which must happen on the GL thread).

RENDER_JOB_CAP :: 64;

RenderJobKind :: enum {
  EMOJI;
  IMAGE;
}

RenderJob :: struct {
  kind:       RenderJobKind;
  glyph:      u32;              // EMOJI
  raw:        *u8;              // IMAGE: raw pixels (owned by the job)
  raw_len:    u64;
  format:     GhosttyKittyImageFormat;
  img_w:      s32;
  img_h:      s32;
  image_id:   u32;
  generation: u64;
}

RenderResult :: struct {
  kind:       RenderJobKind;
  glyph:      u32;
  image_id:   u32;
  generation: u64;
  w:          s32;
  h:          s32;
  color:      bool;
  pixels:     *u8;              // malloc'd RGBA, freed by the consumer
}

RenderWorker :: struct {
  thread:   pthread_t;
  mutex:    pthread_mutex_t;
  running:  bool;
  ft_lib:   *void;
  ft_face:  *FT_FaceRec;

  jobs:     [RENDER_JOB_CAP] RenderJob;
  job_head: s32;
  job_tail: s32;

  results:  [RENDER_JOB_CAP] RenderResult;
  res_head: s32;
  res_tail: s32;
}

render_worker: RenderWorker;

// ---------------------------------------------------------------------------
// Shared glyph-cache helpers

glyph_find :: (eng: *TextEngine, face_index: s32, glyph: u32) -> *GlyphEntry {
  key := GlyphKey.{cast(u16) face_index, glyph};
  hash := (cast(u64) glyph * 2654435761 + cast(u64) face_index * 40503) &
          cast(u64) (GLYPH_CACHE_CAP - 1);
  idx := cast(s32) hash;
  start := idx;
  while eng.glyphs[idx].used {
    g := *eng.glyphs[idx];
    if g.key.face == key.face && g.key.glyph == key.glyph return g;
    idx = (idx + 1) & (GLYPH_CACHE_CAP - 1);
    if idx == start return null;
  }
  return null;
}

glyph_reserve :: (eng: *TextEngine, face_index: s32, glyph: u32) -> *GlyphEntry {
  key := GlyphKey.{cast(u16) face_index, glyph};
  hash := (cast(u64) glyph * 2654435761 + cast(u64) face_index * 40503) &
          cast(u64) (GLYPH_CACHE_CAP - 1);
  idx := cast(s32) hash;
  start := idx;
  while eng.glyphs[idx].used {
    g := *eng.glyphs[idx];
    if g.key.face == key.face && g.key.glyph == key.glyph return g;
    idx = (idx + 1) & (GLYPH_CACHE_CAP - 1);
    if idx == start return *eng.fallback;
  }
  if eng.glyph_count >= GLYPH_CACHE_CAP - 1 return *eng.fallback;
  g := *eng.glyphs[idx];
  g.* = GlyphEntry.{};
  g.used = true;
  g.key = key;
  eng.glyph_count += 1;
  return g;
}

// ---------------------------------------------------------------------------
// SVG / FreeType rasterization (worker side)

svg_glyph_id :: (glyph: u32, buf: *[16] u8) {
  buf.*[0] = 35; // '#'
  for i: 0..4 buf.*[1 + i] = "glyph".data[i];
  digits: [10] u8;
  dn: s32 = 0;
  g := glyph;
  if g == 0 { digits[0] = 48; dn = 1; }
  while g > 0 {
    digits[dn] = cast(u8) (48 + g % 10);
    dn += 1;
    g /= 10;
  }
  pos: s32 = 6;
  i: s32 = dn - 1;
  while i >= 0 {
    buf.*[pos] = digits[i];
    pos += 1;
    i -= 1;
  }
  buf.*[pos] = 0;
}

render_svg_glyph :: (slot: *FT_GlyphSlotRec, w: *s32, h: *s32, out_pixels: **u8) -> bool {
  other_ptr := cast(**void) (cast(*u8) slot + FT_SLOT_OTHER_OFFSET);
  doc := other_ptr.*; // FT_SVG_DocumentRec*
  if doc == null return false;
  doc8 := cast(*u8) doc;
  svg_bytes := (cast(**u8) doc8).*;      // doc->svg_document
  svg_len := (cast(*u64) (doc8 + 8)).*;  // doc->svg_document_length
  if svg_bytes == null || svg_len == 0 return false;

  handle := rsvg_handle_new_from_data(svg_bytes, svg_len, null);
  if handle == null return false;

  id: [16] u8;
  svg_glyph_id(slot.glyph_index, *id);

  upem := cast(float64) slot.face.units_per_EM;
  if upem <= 0.0 upem = 1000.0;
  target_em := 192.0;
  scale := target_em / upem;

  surface := cairo_image_surface_create(0, 1024, 1024); // CAIRO_FORMAT_ARGB32
  if surface == null {
    rsvg_handle_free(handle);
    return false;
  }
  cr := cairo_create(surface);
  if cr == null {
    cairo_surface_destroy(surface);
    rsvg_handle_free(handle);
    return false;
  }
  cairo_scale(cr, scale, scale);
  cairo_translate(cr, 2048.0, 2048.0);
  rsvg_handle_render_cairo_sub(handle, cr, id.data);

  // Crop to the glyph's non-transparent bounding box.
  src := cairo_image_surface_get_data(surface);
  stride := cairo_image_surface_get_stride(surface);
  min_x: s32 = 1024; min_y: s32 = 1024; max_x: s32 = -1; max_y: s32 = -1;
  for y: 0..1023 {
    row := src + y * stride;
    for x: 0..1023 {
      a := row[x * 4 + 3];
      if a > 0 {
        if x < min_x min_x = cast(s32) x;
        if x > max_x max_x = cast(s32) x;
        if y < min_y min_y = cast(s32) y;
        if y > max_y max_y = cast(s32) y;
      }
    }
  }

  if max_x < min_x {
    cairo_destroy(cr);
    cairo_surface_destroy(surface);
    rsvg_handle_free(handle);
    return false;
  }

  cw := max_x - min_x + 1;
  ch := max_y - min_y + 1;
  pixels := malloc(cast(u64) (cw * ch * 4));
  if pixels != null {
    for y: 0..ch-1 {
      srow := src + (min_y + y) * stride;
      for x: 0..cw-1 {
        s := srow + (min_x + x) * 4;
        a := s[3];
        dst := pixels + (y * cw + x) * 4;
        if a > 0 {
          dst[0] = cast(u8) min(255, (cast(s32) s[2] * 255) / cast(s32) a);
          dst[1] = cast(u8) min(255, (cast(s32) s[1] * 255) / cast(s32) a);
          dst[2] = cast(u8) min(255, (cast(s32) s[0] * 255) / cast(s32) a);
        } else {
          dst[0] = 0; dst[1] = 0; dst[2] = 0;
        }
        dst[3] = a;
      }
    }
  }

  cairo_destroy(cr);
  cairo_surface_destroy(surface);
  rsvg_handle_free(handle);

  if pixels == null return false;
  w.* = cw;
  h.* = ch;
  out_pixels.* = pixels;
  return true;
}

// Convert a FreeType bitmap (premultiplied BGRA, or GRAY) into straight RGBA.
ft_bitmap_to_rgba :: (bm: *FT_Bitmap, out_w: *s32, out_h: *s32) -> *u8 {
  w := cast(s32) bm.width;
  h := cast(s32) bm.rows;
  if bm.buffer == null || w <= 0 || h <= 0 return null;
  count := w * h;
  pixels := malloc(cast(u64) (count * 4));
  if pixels == null return null;

  if bm.pixel_mode == FT_PIXEL_MODE_BGRA {
    for y: 0..h-1 {
      row := ifx bm.pitch < 0 then bm.buffer + (h - 1 - y) * (-bm.pitch)
                            else bm.buffer + y * bm.pitch;
      for x: 0..w-1 {
        src := row + x * 4;
        a := src[3];
        dst := pixels + (y * w + x) * 4;
        if a > 0 {
          dst[0] = cast(u8) min(255, (cast(s32) src[2] * 255) / cast(s32) a);
          dst[1] = cast(u8) min(255, (cast(s32) src[1] * 255) / cast(s32) a);
          dst[2] = cast(u8) min(255, (cast(s32) src[0] * 255) / cast(s32) a);
        } else {
          dst[0] = 0; dst[1] = 0; dst[2] = 0;
        }
        dst[3] = a;
      }
    }
  } else {
    for y: 0..h-1 {
      row := ifx bm.pitch < 0 then bm.buffer + (h - 1 - y) * (-bm.pitch)
                            else bm.buffer + y * bm.pitch;
      for x: 0..w-1 {
        a := row[x];
        dst := pixels + (y * w + x) * 4;
        dst[0] = 255; dst[1] = 255; dst[2] = 255; dst[3] = a;
      }
    }
  }

  out_w.* = w;
  out_h.* = h;
  return pixels;
}

// Render a glyph in the (emoji) face to straight RGBA. Returns malloc'd pixels.
render_emoji_glyph :: (face: *FT_FaceRec, glyph: u32,
                       out_w: *s32, out_h: *s32, out_color: *bool) -> *u8 {
  if FT_Load_Glyph(face, glyph, FT_LOAD_COLOR) != 0 return null;
  slot := face.glyph;

  if slot.format == FT_GLYPH_FORMAT_SVG {
    w: s32; h: s32; pixels: *u8;
    if render_svg_glyph(slot, *w, *h, *pixels) {
      out_w.* = w;
      out_h.* = h;
      out_color.* = true;
      return pixels;
    }
    return null;
  }

  if slot.format == FT_GLYPH_FORMAT_OUTLINE {
    FT_Render_Glyph(slot, FT_RENDER_MODE_NORMAL);
  }

  out_color.* = (face.face_flags & FT_FACE_FLAG_COLOR) != 0 &&
                slot.bitmap.pixel_mode == FT_PIXEL_MODE_BGRA;
  return ft_bitmap_to_rgba(*slot.bitmap, out_w, out_h);
}

// Convert raw Kitty image pixels into straight RGBA. Returns malloc'd pixels.
image_pixels_to_rgba :: (raw: *u8, raw_len: u64, format: GhosttyKittyImageFormat,
                         w: s32, h: s32) -> *u8 {
  bpp: u64 = 4;
  if format == .RGB bpp = 3;
  else if format == .GRAY_ALPHA bpp = 2;
  else if format == .GRAY bpp = 1;

  expected := cast(u64) w * cast(u64) h * bpp;
  if raw == null || raw_len < expected || w <= 0 || h <= 0 return null;

  count := cast(u64) w * cast(u64) h;
  rgba := malloc(count * 4);
  if rgba == null return null;

  for i: 0..count-1 {
    dst := rgba + i * 4;
    src := raw + i * bpp;
    if format == .RGBA {
      dst[0] = src[0]; dst[1] = src[1]; dst[2] = src[2]; dst[3] = src[3];
    } else if format == .RGB {
      dst[0] = src[0]; dst[1] = src[1]; dst[2] = src[2]; dst[3] = 255;
    } else if format == .GRAY_ALPHA {
      dst[0] = src[0]; dst[1] = src[0]; dst[2] = src[0]; dst[3] = src[1];
    } else if format == .GRAY {
      dst[0] = src[0]; dst[1] = src[0]; dst[2] = src[0]; dst[3] = 255;
    } else {
      dst[0] = 0; dst[1] = 0; dst[2] = 0; dst[3] = 0;
    }
  }
  return rgba;
}

// ---------------------------------------------------------------------------
// Worker thread

render_worker_main :: (arg: *void) -> *void #c_call {
  push_context {
    worker := cast(*RenderWorker) arg;
    while true {
      job: RenderJob;
      has_job := false;

      pthread_mutex_lock(*worker.mutex);
      if !worker.running {
        pthread_mutex_unlock(*worker.mutex);
        break;
      }
      if worker.job_head != worker.job_tail {
        job = worker.jobs[worker.job_head];
        worker.job_head = (worker.job_head + 1) & (RENDER_JOB_CAP - 1);
        has_job = true;
      }
      pthread_mutex_unlock(*worker.mutex);

      if !has_job {
        usleep(500);
        continue;
      }

      result: RenderResult;
      result = RenderResult.{};
      result.kind = job.kind;

      if job.kind == .EMOJI {
        result.glyph = job.glyph;
        result.pixels = render_emoji_glyph(worker.ft_face, job.glyph,
          *result.w, *result.h, *result.color);
      } else {
        result.image_id = job.image_id;
        result.generation = job.generation;
        result.w = job.img_w;
        result.h = job.img_h;
        result.pixels = image_pixels_to_rgba(job.raw, job.raw_len, job.format, job.img_w, job.img_h);
        if job.raw != null free(job.raw);
      }

      pthread_mutex_lock(*worker.mutex);
      if ((worker.res_tail + 1) & (RENDER_JOB_CAP - 1)) != worker.res_head {
        worker.results[worker.res_tail] = result;
        worker.res_tail = (worker.res_tail + 1) & (RENDER_JOB_CAP - 1);
      } else {
        if result.pixels != null free(result.pixels);
      }
      pthread_mutex_unlock(*worker.mutex);
    }
  }
  return null;
}

render_worker_start :: (emoji_path: *u8, emoji_index: s32) -> bool {
  render_worker.running = false;
  render_worker.job_head = 0;
  render_worker.job_tail = 0;
  render_worker.res_head = 0;
  render_worker.res_tail = 0;

  if emoji_path != null {
    if FT_Init_FreeType(*render_worker.ft_lib) != 0 return false;
    if FT_New_Face(render_worker.ft_lib, emoji_path, cast(s64) emoji_index,
                   *render_worker.ft_face) != 0 return false;
    face := render_worker.ft_face;
    if (face.face_flags & FT_FACE_FLAG_SCALABLE) != 0 {
      FT_Set_Pixel_Sizes(face, 0, 192);
    } else if face.num_fixed_sizes > 0 {
      FT_Select_Size(face, 0);
    }
  }

  pthread_mutex_init(*render_worker.mutex, null);
  render_worker.running = true;
  if pthread_create(*render_worker.thread, null, render_worker_main,
                    cast(*void) *render_worker) != 0 {
    render_worker.running = false;
    return false;
  }
  return true;
}

render_worker_stop :: () {
  pthread_mutex_lock(*render_worker.mutex);
  render_worker.running = false;
  pthread_mutex_unlock(*render_worker.mutex);
  pthread_join(render_worker.thread, null);

  if render_worker.ft_face != null {
    FT_Done_Face(render_worker.ft_face);
    FT_Done_FreeType(render_worker.ft_lib);
  }
  pthread_mutex_destroy(*render_worker.mutex);
}

render_submit_emoji :: (glyph: u32) {
  pthread_mutex_lock(*render_worker.mutex);
  if ((render_worker.job_tail + 1) & (RENDER_JOB_CAP - 1)) != render_worker.job_head {
    job := *render_worker.jobs[render_worker.job_tail];
    job.* = RenderJob.{};
    job.kind = .EMOJI;
    job.glyph = glyph;
    render_worker.job_tail = (render_worker.job_tail + 1) & (RENDER_JOB_CAP - 1);
  }
  pthread_mutex_unlock(*render_worker.mutex);
}

render_submit_image :: (raw: *u8, raw_len: u64, format: GhosttyKittyImageFormat,
                        w: s32, h: s32, image_id: u32, generation: u64) {
  pthread_mutex_lock(*render_worker.mutex);
  if ((render_worker.job_tail + 1) & (RENDER_JOB_CAP - 1)) != render_worker.job_head {
    job := *render_worker.jobs[render_worker.job_tail];
    job.* = RenderJob.{};
    job.kind = .IMAGE;
    job.raw = raw;
    job.raw_len = raw_len;
    job.format = format;
    job.img_w = w;
    job.img_h = h;
    job.image_id = image_id;
    job.generation = generation;
    render_worker.job_tail = (render_worker.job_tail + 1) & (RENDER_JOB_CAP - 1);
  } else {
    if raw != null free(raw);
  }
  pthread_mutex_unlock(*render_worker.mutex);
}

upload_rgba_texture :: (pixels: *u8, w: s32, h: s32) -> Texture2D {
  empty: Texture2D;
  if pixels == null || w <= 0 || h <= 0 return empty;
  im: Image;
  im.data = pixels;
  im.width = w;
  im.height = h;
  im.mipmaps = 1;
  im.format = 7; // PIXELFORMAT_UNCOMPRESSED_R8G8B8A8
  tex := LoadTextureFromImage(im);
  if tex.id != 0 SetTextureFilter(tex, 1); // BILINEAR
  return tex;
}

// Drain worker results and upload them to textures on the GL thread.
render_poll :: (eng: *TextEngine, app: *App) {
  local: [RENDER_JOB_CAP] RenderResult;
  n: s32 = 0;

  pthread_mutex_lock(*render_worker.mutex);
  while render_worker.res_head != render_worker.res_tail && n < RENDER_JOB_CAP {
    local[n] = render_worker.results[render_worker.res_head];
    render_worker.res_head = (render_worker.res_head + 1) & (RENDER_JOB_CAP - 1);
    n += 1;
  }
  pthread_mutex_unlock(*render_worker.mutex);

  for i: 0..n-1 {
    r := local[i];
    if r.pixels == null continue;

    if r.kind == .EMOJI {
      g := glyph_find(eng, eng.emoji, r.glyph);
      if g != null && g.tex.id == 0 {
        g.w = r.w;
        g.h = r.h;
        g.color = r.color;
        g.tex = upload_rgba_texture(r.pixels, r.w, r.h);
      }
    } else {
      e := image_cache_find(app, r.image_id);
      if e != null && e.tex.id == 0 && e.generation == r.generation {
        e.w = r.w;
        e.h = r.h;
        e.tex = upload_rgba_texture(r.pixels, r.w, r.h);
      }
    }
    free(r.pixels);
  }
}

// Request an emoji glyph from the worker, reserving a cache slot for it.
emoji_glyph :: (eng: *TextEngine, glyph: u32) -> *GlyphEntry {
  g := glyph_find(eng, eng.emoji, glyph);
  if g != null return g;
  g = glyph_reserve(eng, eng.emoji, glyph);
  if g == *eng.fallback return g;
  render_submit_emoji(glyph);
  return g;
}
