// A libghostty-vt powered terminal emulator, rendered with Raylib.
//
// libghostty-vt does the VT parsing, screen/grid state, cell styling,
// selection tracking, mouse encoding and Kitty graphics storage.
// Raylib opens the window, takes input and draws everything.
// A PTY (see spawn_shell) connects the emulator to a real shell.
//
// Text is shaped with HarfBuzz and rasterized with FreeType so programming
// ligatures, wide CJK glyphs and colour emoji all work.

Winsize :: struct {
  rows:   u16;
  cols:   u16;
  xpixel: u16;
  ypixel: u16;
}

// ---------------------------------------------------------------------------
// Raylib key / mouse constants

RK_SPACE         :: 32;
RK_APOSTROPHE    :: 39;
RK_COMMA         :: 44;
RK_MINUS         :: 45;
RK_PERIOD        :: 46;
RK_SLASH         :: 47;
RK_ZERO          :: 48;
RK_NINE          :: 57;
RK_SEMICOLON     :: 59;
RK_EQUAL         :: 61;
RK_A             :: 65;
RK_Z             :: 90;
RK_LEFT_BRACKET  :: 91;
RK_BACKSLASH     :: 92;
RK_RIGHT_BRACKET :: 93;
RK_GRAVE         :: 96;
RK_ESCAPE        :: 256;
RK_ENTER         :: 257;
RK_TAB           :: 258;
RK_BACKSPACE     :: 259;
RK_INSERT        :: 260;
RK_DELETE        :: 261;
RK_RIGHT         :: 262;
RK_LEFT          :: 263;
RK_DOWN          :: 264;
RK_UP            :: 265;
RK_PAGE_UP       :: 266;
RK_PAGE_DOWN     :: 267;
RK_HOME          :: 268;
RK_END           :: 269;
RK_F1            :: 290;
RK_F12           :: 301;
RK_LEFT_SHIFT    :: 340;
RK_LEFT_CONTROL  :: 341;
RK_LEFT_ALT      :: 342;
RK_LEFT_SUPER    :: 343;
RK_RIGHT_SHIFT   :: 344;
RK_RIGHT_CONTROL :: 345;
RK_RIGHT_ALT     :: 346;
RK_RIGHT_SUPER   :: 347;
RK_KP_0          :: 320;
RK_KP_9          :: 329;
RK_KP_DECIMAL    :: 330;
RK_KP_DIVIDE     :: 331;
RK_KP_MULTIPLY   :: 332;
RK_KP_SUBTRACT   :: 333;
RK_KP_ADD         :: 334;
RK_KP_ENTER      :: 335;
RK_KP_EQUAL      :: 336;

RM_LEFT   :: 0;
RM_RIGHT  :: 1;
RM_MIDDLE :: 2;

// GhosttyKey numeric bases (the enum is append-only within a version).
GK_DIGIT_0  :: 6;
GK_A        :: 20;
GK_NUMPAD_0 :: 80;
GK_F1       :: 121;

// ---------------------------------------------------------------------------
// Text engine

MAX_TEXT_FACES  :: 16;
GLYPH_CACHE_CAP :: 32768;
MAX_COLS        :: 512;

GlyphKey :: struct {
  face:  u16;
  glyph: u32;
}

GlyphEntry :: struct {
  used:    bool;
  key:     GlyphKey;
  tex:     Texture2D;
  w:       s32;
  h:       s32;
  left:    s32;
  top:     s32;
  advance: float;
  color:   bool;
}

TextFace :: struct {
  ft:        *FT_FaceRec;
  hb:        *void;
  color:     bool;
  ascender:  float;
  descender: float;
}

TextEngine :: struct {
  lib:        *void;
  faces:      [MAX_TEXT_FACES] TextFace;
  face_count: s32;
  primary:    s32;
  emoji:      s32;
  emoji_path: [1024] u8;
  emoji_index: s32;
  glyphs:     [GLYPH_CACHE_CAP] GlyphEntry;
  glyph_count: s32;
  fallback:   GlyphEntry;
  hb_buf:     *void;
  size_px:    s32;
  cell_w:     float;
  baseline:   float;
}

// Copy a NUL-terminated string from `src` into `dst` (a fixed buffer), and
// return true on success. Used to stash Fontconfig file paths.
copy_cstr :: (src: *u8, dst: *[1024] u8) -> bool {
  len := strlen(src);
  if len + 1 >= dst.count return false;
  for i: 0..len dst.*[i] = src[i];
  dst.*[len] = 0;
  return true;
}

// Find a font file for a given family name. When `scalable` is true the match
// is restricted to scalable (outline) faces; colour emoji fonts are bitmap
// strikes and must be looked up with scalable=false.
fc_find_family :: (family: *u8, scalable: bool, path: *[1024] u8, index: *s32) -> bool {
  pat := FcPatternCreate();
  if pat == null return false;
  FcPatternAddString(pat, "family", family);
  if scalable FcPatternAddBool(pat, "scalable", 1);

  config := FcConfigGetCurrent();
  FcConfigSubstitute(config, pat, 0); // FcMatchPattern
  FcDefaultSubstitute(pat);

  res: s32 = 0;
  ok := false;
  match := FcFontMatch(config, pat, *res);
  if match != null {
    file: *u8;
    idx: s32 = 0;
    if FcPatternGetString(match, "file", 0, *file) == 0 &&
       FcPatternGetInteger(match, "index", 0, *idx) == 0 {
      ok = copy_cstr(file, path);
      index.* = idx;
    }
    FcPatternDestroy(match);
  }
  FcPatternDestroy(pat);
  return ok;
}

// Find any font on the system that covers a codepoint, via a Fontconfig
// charset query. This is the general fallback for glyphs the primary face
// does not contain (CJK, symbols, etc.).
fc_find_for_cp :: (cp: u32, path: *[1024] u8, index: *s32) -> bool {
  cs := FcCharSetCreate();
  FcCharSetAddChar(cs, cp);
  pat := FcPatternCreate();
  FcPatternAddCharSet(pat, "charset", cs);

  config := FcConfigGetCurrent();
  FcConfigSubstitute(config, pat, 0); // FcMatchPattern
  FcDefaultSubstitute(pat);

  res: s32 = 0;
  ok := false;
  set := FcFontSort(config, pat, 1, null, *res);
  if set != null {
    for i: 0..set.nfont-1 {
      fp := set.fonts[i];
      if fp == null continue;
      file: *u8;
      if FcPatternGetString(fp, "file", 0, *file) != 0 continue;
      fcs: *void;
      if FcPatternGetCharSet(fp, "charset", 0, *fcs) == 0 && fcs != null {
        if FcCharSetHasChar(fcs, cp) == 0 continue;
      }
      idx: s32 = 0;
      if FcPatternGetInteger(fp, "index", 0, *idx) != 0 idx = 0;
      if copy_cstr(file, path) {
        index.* = idx;
        ok = true;
      }
      break;
    }
    FcFontSetDestroy(set);
  }
  FcPatternDestroy(pat);
  FcCharSetDestroy(cs);
  return ok;
}

TextEngine_load_face :: (eng: *TextEngine, path: *u8, face_index: s32) -> s32 {
  if eng.face_count >= MAX_TEXT_FACES return -1;
  ft: *FT_FaceRec;
  if FT_New_Face(eng.lib, path, cast(s64) face_index, *ft) != 0 return -1;

  if (ft.face_flags & FT_FACE_FLAG_SCALABLE) != 0 {
    if FT_Set_Pixel_Sizes(ft, 0, cast(u32) eng.size_px) != 0 {
      FT_Done_Face(ft);
      return -1;
    }
  } else if ft.num_fixed_sizes > 0 {
    FT_Select_Size(ft, 0);
  }

  blob := hb_blob_create_from_file(path);
  if blob == null {
    FT_Done_Face(ft);
    return -1;
  }
  hb_face := hb_face_create(blob, cast(u32) face_index);
  hb_blob_destroy(blob);
  if hb_face == null {
    FT_Done_Face(ft);
    return -1;
  }
  hb_font := hb_font_create(hb_face);
  hb_face_destroy(hb_face);
  if hb_font == null {
    FT_Done_Face(ft);
    return -1;
  }
  hb_font_set_scale(hb_font, eng.size_px * 64, eng.size_px * 64);

  idx := eng.face_count;
  face := *eng.faces[idx];
  face.ft = ft;
  face.hb = hb_font;
  face.color = (ft.face_flags & FT_FACE_FLAG_COLOR) != 0;
  upem := cast(float) ft.units_per_EM;
  if upem <= 0.0 upem = 1000.0;
  face.ascender = cast(float) ft.ascender * cast(float) eng.size_px / upem;
  face.descender = cast(float) ft.descender * cast(float) eng.size_px / upem;
  eng.face_count += 1;
  return idx;
}

TextEngine_load_family :: (eng: *TextEngine, family: *u8, scalable: bool) -> s32 {
  path: [1024] u8;
  index: s32 = 0;
  if !fc_find_family(family, scalable, *path, *index) return -1;
  return TextEngine_load_face(eng, path.data, index);
}

// Load (or reuse) a face that covers `cp`, discovered with Fontconfig.
TextEngine_load_for_cp :: (eng: *TextEngine, cp: u32) -> s32 {
  path: [1024] u8;
  index: s32 = 0;
  if !fc_find_for_cp(cp, *path, *index) return -1;
  return TextEngine_load_face(eng, path.data, index);
}

TextEngine_init :: (eng: *TextEngine, size: s32, custom_font: *u8) -> bool {
  eng.size_px = size;
  eng.primary = -1;
  eng.emoji = -1;
  FcInit();
  if FT_Init_FreeType(*eng.lib) != 0 {
    print("Could not initialize FreeType.\n");
    return false;
  }
  eng.hb_buf = hb_buffer_create();
  if eng.hb_buf == null {
    print("Could not create a HarfBuzz buffer.\n");
    return false;
  }

  // A font chosen in the config file wins over the built-in preference list.
  if custom_font != null && custom_font[0] != 0 {
    eng.primary = TextEngine_load_family(eng, custom_font, true);
    if eng.primary >= 0 {
      // Keep going: emoji and fallbacks are still loaded below.
    } else {
      print("Configured font '%' was not found; falling back.\n", cstr_to_string(custom_font));
    }
  }

  if eng.primary < 0 {
    // Primary monospace face, most preferred first. Nerd Font families carry
    // the private-use glyphs prompts and file managers use.
    monospace_families: [12] string = .[
      "JetBrainsMono Nerd Font Mono",
      "JetBrainsMono Nerd Font",
      "JetBrains Mono",
      "FiraCode Nerd Font",
      "Cascadia Mono",
      "Cascadia Code",
      "Ubuntu Mono",
      "Noto Sans Mono",
      "Liberation Mono",
      "DejaVu Sans Mono",
      "Courier New",
      "monospace",
    ];
    for i: 0..monospace_families.count-1 {
      f := monospace_families[i];
      eng.primary = TextEngine_load_family(eng, f.data, true);
      if eng.primary >= 0 break;
    }
  }
  if eng.primary < 0 {
    print("Could not find a monospace font with Fontconfig.\n");
    return false;
  }

  // Colour emoji face. These are bitmap fonts, so ask Fontconfig without the
  // scalable filter. If none of the well-known families exist, fall back to
  // whatever Fontconfig recommends for a generic emoji codepoint.
  emoji_families: [6] string = .[
    "Noto Color Emoji",
    "EmojiOne Color",
    "Twemoji Mozilla",
    "Segoe UI Emoji",
    "Apple Color Emoji",
    "Noto Emoji",
  ];
  for i: 0..emoji_families.count-1 {
    f := emoji_families[i];
    path: [1024] u8;
    index: s32 = 0;
    if fc_find_family(f.data, false, *path, *index) {
      eng.emoji = TextEngine_load_face(eng, path.data, index);
      if eng.emoji >= 0 {
        copy_cstr(path.data, *eng.emoji_path);
        eng.emoji_index = index;
        break;
      }
    }
  }
  if eng.emoji < 0 {
    path: [1024] u8;
    index: s32 = 0;
    if fc_find_for_cp(0x1F600, *path, *index) {
      eng.emoji = TextEngine_load_face(eng, path.data, index);
      if eng.emoji >= 0 {
        copy_cstr(path.data, *eng.emoji_path);
        eng.emoji_index = index;
      }
    }
  }

  p := eng.faces[eng.primary];
  eng.cell_w = TextEngine_advance(eng, eng.primary, 77); // 'M'
  if eng.cell_w <= 0.0 eng.cell_w = cast(float) size * 0.6;
  return true;
}

TextEngine_advance :: (eng: *TextEngine, face_index: s32, cp: u32) -> float {
  face := *eng.faces[face_index];
  glyph := FT_Get_Char_Index(face.ft, cp);
  if FT_Load_Glyph(face.ft, glyph, 0) != 0 return 0.0;
  return cast(float) face.ft.glyph.advance.x / 64.0;
}

utf8_decode_one :: (s: *u8, len: u64, i: *u64) -> u32 {
  if i.* >= len return 0;
  b0 := s[i.*];
  i.* += 1;
  if b0 < 0x80 return cast(u32) b0;
  if (b0 & 0xE0) == 0xC0 && i.* < len {
    b1 := s[i.*]; i.* += 1;
    return (cast(u32) (b0 & 0x1F) << 6) | cast(u32) (b1 & 0x3F);
  }
  if (b0 & 0xF0) == 0xE0 && i.* + 1 < len {
    b1 := s[i.*]; b2 := s[i.* + 1]; i.* += 2;
    return ((cast(u32) (b0 & 0x0F)) << 12) |
           ((cast(u32) (b1 & 0x3F)) << 6) | cast(u32) (b2 & 0x3F);
  }
  if (b0 & 0xF8) == 0xF0 && i.* + 2 < len {
    b1 := s[i.*]; b2 := s[i.* + 1]; b3 := s[i.* + 2]; i.* += 3;
    return ((cast(u32) (b0 & 0x07)) << 18) |
           ((cast(u32) (b1 & 0x3F)) << 12) |
           ((cast(u32) (b2 & 0x3F)) << 6) | cast(u32) (b3 & 0x3F);
  }
  return 0xFFFD;
}

utf8_decode :: (s: *u8, len: u64, cps: *[32] u32) -> s32 {
  n: s32 = 0;
  i: u64 = 0;
  while i < len && n < cps.count {
    cp := utf8_decode_one(s, len, *i);
    if cp == 0 break;
    cps.*[n] = cp;
    n += 1;
  }
  return n;
}

cell_text_width :: (s: *u8, len: u64) -> s32 {
  if len == 0 return 0;
  cps: [32] u32;
  n := utf8_decode(s, len, *cps);
  if n <= 0 return 0;
  w: u8;
  ghostty_unicode_grapheme_width(cps.data, cast(u64) n, *w);
  return cast(s32) w;
}

is_emoji_cp :: (cp: u32) -> bool {
  if cp >= 0x1F000 && cp <= 0x1FAFF return true;
  if cp >= 0x2600 && cp <= 0x27BF return true;
  if cp >= 0x2B00 && cp <= 0x2BFF return true;
  if cp >= 0x1F1E6 && cp <= 0x1F1FF return true;
  return false;
}

face_covers :: (eng: *TextEngine, face_index: s32, cps: *[32] u32, n: s32) -> bool {
  face := *eng.faces[face_index];
  for i: 0..n-1 {
    cp := cps.*[i];
    if cp == 0x200D || cp == 0xFE0E || cp == 0xFE0F continue;
    if cp < 0x20 continue;
    if FT_Get_Char_Index(face.ft, cp) == 0 return false;
  }
  return true;
}

pick_face :: (eng: *TextEngine, cps: *[32] u32, n: s32) -> s32 {
  if n <= 0 return eng.primary;
  emoji_like := false;
  first: u32 = 0;
  for i: 0..n-1 {
    cp := cps.*[i];
    if first == 0 && cp != 0x200D && cp != 0xFE0E && cp != 0xFE0F && cp >= 0x20 first = cp;
    if is_emoji_cp(cp) { emoji_like = true; }
  }
  if emoji_like && eng.emoji >= 0 && face_covers(eng, eng.emoji, cps, n) {
    return eng.emoji;
  }
  if face_covers(eng, eng.primary, cps, n) return eng.primary;
  if eng.emoji >= 0 && face_covers(eng, eng.emoji, cps, n) return eng.emoji;
  for i: 1..eng.face_count-1 {
    if i == eng.emoji continue;
    if face_covers(eng, i, cps, n) return i;
  }
  if first != 0 {
    fi := TextEngine_load_for_cp(eng, first);
    if fi >= 0 && face_covers(eng, fi, cps, n) return fi;
  }
  return eng.primary;
}

pick_face_utf8 :: (eng: *TextEngine, s: *u8, len: u64) -> s32 {
  cps: [32] u32;
  n := utf8_decode(s, len, *cps);
  return pick_face(eng, *cps, n);
}

TextEngine_glyph :: (eng: *TextEngine, face_index: s32, glyph: u32) -> *GlyphEntry {
  if face_index < 0 || face_index >= eng.face_count return *eng.fallback;

  // Colour emoji (including OT-SVG) are rasterized on the worker thread.
  if face_index == eng.emoji {
    return emoji_glyph(eng, glyph);
  }

  g := glyph_find(eng, face_index, glyph);
  if g != null return g;
  g = glyph_reserve(eng, face_index, glyph);
  if g == *eng.fallback return g;

  face := *eng.faces[face_index];
  if FT_Load_Glyph(face.ft, glyph, FT_LOAD_COLOR) != 0 {
    return g;
  }
  slot := face.ft.glyph;
  g.advance = cast(float) slot.advance.x / 64.0;
  g.left = slot.bitmap_left;
  g.top = slot.bitmap_top;

  if slot.format == FT_GLYPH_FORMAT_SVG {
    // SVG glyphs only live in the emoji face, which is handled by the worker.
    return g;
  }

  if slot.format == FT_GLYPH_FORMAT_OUTLINE {
    FT_Render_Glyph(slot, FT_RENDER_MODE_NORMAL);
  }

  bm := slot.bitmap;
  g.w = cast(s32) bm.width;
  g.h = cast(s32) bm.rows;
  g.color = face.color && bm.pixel_mode == FT_PIXEL_MODE_BGRA;

  if bm.buffer != null && g.w > 0 && g.h > 0 {
    pw: s32; ph: s32;
    pixels := ft_bitmap_to_rgba(*bm, *pw, *ph);
    if pixels != null {
      g.tex = upload_rgba_texture(pixels, g.w, g.h);
      free(pixels);
    }
  }
  return g;
}

// ---------------------------------------------------------------------------
// Kitty graphics texture cache

MAX_IMAGE_PLACEMENTS :: 128;
IMAGE_CACHE_CAP      :: 64;

ImagePlacement :: struct {
  protocol:   u32;
  image_id:   u32;
  generation: u64;
  layer:      u32;
  z:          s32;
  col:        s32;
  row:        s32;
  offset_x:   u32;
  offset_y:   u32;
  pixel_w:    u32;
  pixel_h:    u32;
  source_x:   u32;
  source_y:   u32;
  source_w:   u32;
  source_h:   u32;
}

ImageCacheEntry :: struct {
  used:      bool;
  id:        u32;
  generation: u64;
  tex:       Texture2D;
  w:         s32;
  h:         s32;
  last_used: u64;
}

// ---------------------------------------------------------------------------
// Application state

Config :: struct {
  font:        [256] u8;
  has_font:    bool;
  bg:          GhosttyColorRgb;
  fg:          GhosttyColorRgb;
  cursor:      GhosttyColorRgb;
  has_bg:      bool;
  has_fg:      bool;
  has_cursor:  bool;
  palette:     [16] GhosttyColorRgb;
  has_palette: [16] bool;
}

App :: struct {
  config:     Config;
  term:       GhosttyTerminal;
  render:     GhosttyRenderState;
  rows_iter:  GhosttyRenderStateRowIterator;
  cells:      GhosttyRenderStateRowCells;
  img_iter:   GhosttyRenderStateImageIterator;
  key_event:  GhosttyKeyEvent;
  key_enc:    GhosttyKeyEncoder;

  sel_gesture: *GhosttySelectionGestureImpl;
  sel_press:   GhosttySelectionGestureEvent;
  sel_drag:    GhosttySelectionGestureEvent;
  sel_release: GhosttySelectionGestureEvent;
  sel_dragging: bool;

  mouse_event: GhosttyMouseEvent;
  mouse_enc:   GhosttyMouseEncoder;

  formatter:   GhosttyFormatter;

  master:     s32;
  child_pid:  s32;
  child_dead: bool;

  cols:       u16;
  rows:       u16;
  cell_w:     float;
  cell_h:     float;
  font_size:  float;
  pad_x:      float;
  pad_y:      float;
  baseline:   float;
  text:       TextEngine;

  img_placements: [MAX_IMAGE_PLACEMENTS] ImagePlacement;
  img_count:      s32;
  img_cache:      [IMAGE_CACHE_CAP] ImageCacheEntry;
  frame:          u64;

  title_buf:  [512] u8;
  title_len:  u64;

  shot_path:  *u8;
  shot_done:  bool;
}

KEY_LIST: [128] s32;
KEY_COUNT: s32;

add_key :: (k: s32) {
  KEY_LIST[KEY_COUNT] = k;
  KEY_COUNT += 1;
}

init_key_list :: () {
  KEY_COUNT = 0;
  for k: RK_A..RK_Z       { add_key(cast(s32) k); }
  for k: RK_ZERO..RK_NINE { add_key(cast(s32) k); }
  add_key(RK_SPACE); add_key(RK_APOSTROPHE); add_key(RK_COMMA); add_key(RK_MINUS);
  add_key(RK_PERIOD); add_key(RK_SLASH); add_key(RK_SEMICOLON); add_key(RK_EQUAL);
  add_key(RK_LEFT_BRACKET); add_key(RK_BACKSLASH); add_key(RK_RIGHT_BRACKET); add_key(RK_GRAVE);

  add_key(RK_ESCAPE); add_key(RK_ENTER); add_key(RK_TAB); add_key(RK_BACKSPACE);
  add_key(RK_INSERT); add_key(RK_DELETE);
  add_key(RK_RIGHT); add_key(RK_LEFT); add_key(RK_DOWN); add_key(RK_UP);
  add_key(RK_PAGE_UP); add_key(RK_PAGE_DOWN); add_key(RK_HOME); add_key(RK_END);

  for k: RK_F1..RK_F12 { add_key(cast(s32) k); }

  for k: RK_KP_0..RK_KP_9 { add_key(cast(s32) k); }
  add_key(RK_KP_DECIMAL); add_key(RK_KP_DIVIDE); add_key(RK_KP_MULTIPLY);
  add_key(RK_KP_SUBTRACT); add_key(RK_KP_ADD); add_key(RK_KP_ENTER); add_key(RK_KP_EQUAL);
}

// ---------------------------------------------------------------------------
// PTY

spawn_shell :: (app: *App, cols: u16, rows: u16) -> bool {
  master := posix_openpt(O_RDWR | O_NOCTTY);
  if master < 0 {
    print("Could not open a pseudo-terminal: errno=%\n", errno());
    return false;
  }
  if grantpt(master) != 0 || unlockpt(master) != 0 {
    print("Could not prepare the pseudo-terminal: errno=%\n", errno());
    close(master);
    return false;
  }
  slave_name := ptsname(master);
  if slave_name == null {
    close(master);
    return false;
  }
  slave := open(slave_name, O_RDWR | O_NOCTTY);
  if slave < 0 {
    print("Could not open the pty slave: errno=%\n", errno());
    close(master);
    return false;
  }

  ws: Winsize;
  ws.cols = cols;
  ws.rows = rows;

  pid := fork();
  if pid < 0 {
    print("Could not fork: errno=%\n", errno());
    close(slave);
    close(master);
    return false;
  }

  if pid == 0 {
    // Child: become a session leader, attach the pty as controlling tty,
    // then make it stdin/stdout/stderr and exec the user's shell.
    close(master);
    setsid();
    ioctl(slave, TIOCSCTTY, 0);
    setenv("TERM", "xterm-256color", 1);
    setenv("COLORTERM", "truecolor", 1);
    setenv("TERM_PROGRAM", "josh", 1);
    dup2(slave, 0);
    dup2(slave, 1);
    dup2(slave, 2);
    if slave > 2 close(slave);

    shell := getenv("SHELL");
    if shell == null || shell[0] == 0 shell = "/bin/bash";
    argv: [2] *u8;
    argv[0] = shell;
    argv[1] = null;
    execvp(shell, argv.data);
    _exit(127);
  }

  close(slave);
  fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK);

  app.master = master;
  app.child_pid = pid;
  app.child_dead = false;
  app.cols = cols;
  app.rows = rows;
  set_pty_size(app);

  return true;
}

set_pty_size :: (app: *App) {
  ws: Winsize;
  ws.cols = app.cols;
  ws.rows = app.rows;
  ioctl(app.master, TIOCSWINSZ, *ws);
}

pump_pty :: (app: *App) -> s32 {
  if app.child_dead return 0;
  buf: [65536] u8;
  total: s32 = 0;
  while true {
    n := read(app.master, buf.data, 65536);
    if n > 0 {
      ghostty_terminal_vt_write(app.term, buf.data, cast(u64) n);
      total += cast(s32) n;
      continue;
    }
    if n < 0 && errno() == 11 { // EAGAIN
      break;
    }
    // EOF/EIO: the shell (or the pty) went away. Close the window.
    app.child_dead = true;
    break;
  }
  return total;
}

write_pty :: (app: *App, data: *u8, len: u64) {
  if app.child_dead || app.master < 0 return;
  off: u64 = 0;
  stall := 0;
  while off < len {
    n := write(app.master, data + off, len - off);
    if n > 0 {
      off += cast(u64) n;
      stall = 0;
    } else if n < 0 && errno() == 11 {
      usleep(1000);
      stall += 1;
      if stall > 100 break;
    } else {
      break;
    }
  }
}

// ---------------------------------------------------------------------------
// Keyboard input

utf8_encode :: (cp: u32, out: *u8) -> s32 {
  if cp < 0x80 {
    out[0] = cast(u8) cp;
    return 1;
  }
  if cp < 0x800 {
    out[0] = cast(u8) (0xC0 | (cp >> 6));
    out[1] = cast(u8) (0x80 | (cp & 0x3F));
    return 2;
  }
  if cp < 0x10000 {
    out[0] = cast(u8) (0xE0 | (cp >> 12));
    out[1] = cast(u8) (0x80 | ((cp >> 6) & 0x3F));
    out[2] = cast(u8) (0x80 | (cp & 0x3F));
    return 3;
  }
  out[0] = cast(u8) (0xF0 | (cp >> 18));
  out[1] = cast(u8) (0x80 | ((cp >> 12) & 0x3F));
  out[2] = cast(u8) (0x80 | ((cp >> 6) & 0x3F));
  out[3] = cast(u8) (0x80 | (cp & 0x3F));
  return 4;
}

key_to_ghostty :: (key: s32) -> GhosttyKey {
  if key >= RK_A && key <= RK_Z {
    return cast(GhosttyKey) (GK_A + (key - RK_A));
  }
  if key >= RK_ZERO && key <= RK_NINE {
    return cast(GhosttyKey) (GK_DIGIT_0 + (key - RK_ZERO));
  }
  if key >= RK_F1 && key <= RK_F12 {
    return cast(GhosttyKey) (GK_F1 + (key - RK_F1));
  }
  if key >= RK_KP_0 && key <= RK_KP_9 {
    return cast(GhosttyKey) (GK_NUMPAD_0 + (key - RK_KP_0));
  }

  if key == {
    case RK_SPACE;         return .SPACE;
    case RK_APOSTROPHE;    return .QUOTE;
    case RK_COMMA;         return .COMMA;
    case RK_MINUS;         return .MINUS;
    case RK_PERIOD;        return .PERIOD;
    case RK_SLASH;         return .SLASH;
    case RK_SEMICOLON;     return .SEMICOLON;
    case RK_EQUAL;         return .EQUAL;
    case RK_LEFT_BRACKET;  return .BRACKET_LEFT;
    case RK_BACKSLASH;     return .BACKSLASH;
    case RK_RIGHT_BRACKET; return .BRACKET_RIGHT;
    case RK_GRAVE;         return .BACKQUOTE;
    case RK_ESCAPE;        return .ESCAPE;
    case RK_ENTER;         return .ENTER;
    case RK_TAB;           return .TAB;
    case RK_BACKSPACE;     return .BACKSPACE;
    case RK_INSERT;        return .INSERT;
    case RK_DELETE;        return .DELETE;
    case RK_RIGHT;         return .ARROW_RIGHT;
    case RK_LEFT;          return .ARROW_LEFT;
    case RK_DOWN;          return .ARROW_DOWN;
    case RK_UP;            return .ARROW_UP;
    case RK_PAGE_UP;       return .PAGE_UP;
    case RK_PAGE_DOWN;     return .PAGE_DOWN;
    case RK_HOME;          return .HOME;
    case RK_END;           return .END;
    case RK_KP_DECIMAL;    return .NUMPAD_DECIMAL;
    case RK_KP_DIVIDE;     return .NUMPAD_DIVIDE;
    case RK_KP_MULTIPLY;   return .NUMPAD_MULTIPLY;
    case RK_KP_SUBTRACT;   return .NUMPAD_SUBTRACT;
    case RK_KP_ADD;        return .NUMPAD_ADD;
    case RK_KP_ENTER;      return .NUMPAD_ENTER;
    case RK_KP_EQUAL;      return .NUMPAD_EQUAL;
  }
  return .UNIDENTIFIED;
}

key_is_printable :: (key: s32) -> bool {
  if key >= RK_A && key <= RK_Z return true;
  if key >= RK_ZERO && key <= RK_NINE return true;
  if key == RK_SPACE return true;
  if key == {
    case RK_APOSTROPHE; case RK_COMMA; case RK_MINUS; case RK_PERIOD;
    case RK_SLASH; case RK_SEMICOLON; case RK_EQUAL; case RK_LEFT_BRACKET;
    case RK_BACKSLASH; case RK_RIGHT_BRACKET; case RK_GRAVE;
      return true;
  }
  return false;
}

key_unshifted :: (key: s32) -> u32 {
  if key >= RK_A && key <= RK_Z return cast(u32) (97 + (key - RK_A));
  if key >= RK_ZERO && key <= RK_NINE return cast(u32) (48 + (key - RK_ZERO));
  if key == {
    case RK_SPACE;         return 32;
    case RK_APOSTROPHE;    return 39;
    case RK_COMMA;         return 44;
    case RK_MINUS;         return 45;
    case RK_PERIOD;        return 46;
    case RK_SLASH;         return 47;
    case RK_SEMICOLON;     return 59;
    case RK_EQUAL;         return 61;
    case RK_LEFT_BRACKET;  return 91;
    case RK_BACKSLASH;     return 92;
    case RK_RIGHT_BRACKET; return 93;
    case RK_GRAVE;         return 96;
  }
  return 0;
}

key_shifted :: (key: s32) -> u32 {
  if key >= RK_A && key <= RK_Z return cast(u32) (65 + (key - RK_A));
  if key >= RK_ZERO && key <= RK_NINE return 0; // handled by the char callback
  if key == {
    case RK_SPACE;         return 32;
    case RK_APOSTROPHE;    return 34;
    case RK_COMMA;         return 60;
    case RK_MINUS;         return 95;
    case RK_PERIOD;        return 62;
    case RK_SLASH;         return 63;
    case RK_SEMICOLON;     return 58;
    case RK_EQUAL;         return 43;
    case RK_LEFT_BRACKET;  return 123;
    case RK_BACKSLASH;     return 124;
    case RK_RIGHT_BRACKET; return 125;
    case RK_GRAVE;         return 126;
  }
  return 0;
}

sent_key :: (app: *App, key: s32, mods: u16, cp: u32, repeat: bool) {
  gkey := key_to_ghostty(key);
  if gkey == .UNIDENTIFIED return;

  ghostty_key_event_set_key(app.key_event, gkey);
  ghostty_key_event_set_mods(app.key_event, mods);
  ghostty_key_event_set_action(app.key_event,
    ifx repeat then GhosttyKeyAction.REPEAT else GhosttyKeyAction.PRESS);

  text: [4] u8;
  n := 0;
  if cp != 0 n = utf8_encode(cp, text.data);
  ghostty_key_event_set_utf8(app.key_event, GhosttyString.{text.data, cast(u64) n});
  ghostty_key_event_set_unshifted_codepoint(app.key_event,
    ifx cp != 0 then cp else key_unshifted(key));

  buf: [128] u8;
  written: u64;
  res := ghostty_key_encoder_encode(app.key_enc, app.key_event, buf.data, 128, *written);
  if res == .SUCCESS && written > 0 {
    write_pty(app, buf.data, written);
  }
}

paste_clipboard :: (app: *App) {
  text := GetClipboardText();
  if text == null return;
  len := strlen(text);
  if len > 0 write_pty(app, text, len);
}

scroll_viewport :: (app: *App, delta: s64) {
  scroll: GhosttyTerminalScrollViewport;
  scroll.tag = .DELTA;
  scroll.value.delta = delta;
  ghostty_terminal_scroll_viewport(app.term, scroll);
}

scroll_to_bottom :: (app: *App) {
  scroll: GhosttyTerminalScrollViewport;
  scroll.tag = .BOTTOM;
  ghostty_terminal_scroll_viewport(app.term, scroll);
}

copy_selection :: (app: *App) -> bool {
  sel: GhosttySelection;
  if ghostty_terminal_get(app.term, .SELECTION, *sel) != .SUCCESS return false;

  emit: GhosttyFormatterFormat = .PLAIN;
  unwrap := true;
  trim := true;
  ghostty_formatter_set(app.formatter, .EMIT, *emit);
  ghostty_formatter_set(app.formatter, .UNWRAP, *unwrap);
  ghostty_formatter_set(app.formatter, .TRIM, *trim);
  if ghostty_formatter_set(app.formatter, .SELECTION, *sel) != .SUCCESS return false;

  needed: u64;
  res := ghostty_formatter_format_buf(app.formatter, null, 0, *needed);
  if needed == 0 return false;
  buf := malloc(needed + 1);
  if buf == null return false;
  written: u64;
  ok := false;
  if ghostty_formatter_format_buf(app.formatter, buf, needed, *written) == .SUCCESS {
    buf[written] = 0;
    SetClipboardText(buf);
    ok = true;
  }
  free(buf);
  return ok;
}

handle_keyboard :: (app: *App) {
  // Raw text. This is where layout-specific and dead-key characters come
  // from, so it drives normal typing.
  chars: [64] u32;
  char_count := 0;
  while true {
    c := GetCharPressed();
    if c == 0 break;
    if char_count < chars.count {
      chars[char_count] = cast(u32) c;
      char_count += 1;
    }
  }

  ctrl  := IsKeyDown(RK_LEFT_CONTROL) || IsKeyDown(RK_RIGHT_CONTROL);
  alt   := IsKeyDown(RK_LEFT_ALT) || IsKeyDown(RK_RIGHT_ALT);
  shift := IsKeyDown(RK_LEFT_SHIFT) || IsKeyDown(RK_RIGHT_SHIFT);
  super := IsKeyDown(RK_LEFT_SUPER) || IsKeyDown(RK_RIGHT_SUPER);

  mods: u16 = 0;
  if shift mods |= GHOSTTY_MODS_SHIFT;
  if ctrl  mods |= GHOSTTY_MODS_CTRL;
  if alt   mods |= GHOSTTY_MODS_ALT;
  if super mods |= GHOSTTY_MODS_SUPER;

  had_input := false;

  for i: 0..KEY_COUNT-1 {
    k := KEY_LIST[i];
    pressed := IsKeyPressed(k);
    repeat := IsKeyPressedRepeat(k);
    if !pressed && !repeat continue;

    if ctrl && shift && k == 86 { // Ctrl+Shift+V
      if pressed paste_clipboard(app);
      continue;
    }
    if ctrl && shift && k == 67 { // Ctrl+Shift+C
      if pressed copy_selection(app);
      continue;
    }

    if super {
      // Leave window-manager shortcuts alone.
      continue;
    }

    if k == RK_F12 && pressed {
      TakeScreenshot("jai-terminal.png");
      continue;
    }
    had_input = true;

    printable := key_is_printable(k);

    if ctrl || alt {
      cp: u32 = 0;
      if printable {
        cp = ifx shift then key_shifted(k) else key_unshifted(k);
        if cp == 0 cp = key_unshifted(k);
      }
      sent_key(app, k, mods, cp, repeat);
      continue;
    }

    if printable {
      // The first press arrives through GetCharPressed. Key repeat for
      // letters/digits is not always reported there, so synthesize repeats.
      if repeat {
        cp := ifx shift then key_shifted(k) else key_unshifted(k);
        if cp != 0 sent_key(app, k, mods, cp, true);
      }
      continue;
    }

    sent_key(app, k, mods, 0, repeat);
  }

  // With a modifier held we already encoded the key event above, and some
  // platforms also report a control character through GetCharPressed.
  if !ctrl && !alt && !super {
    buf: [4] u8;
    for i: 0..char_count-1 {
      n := utf8_encode(chars[i], buf.data);
      write_pty(app, buf.data, cast(u64) n);
    }
  }

  // Typing always brings the viewport back to the live screen.
  if had_input || (!ctrl && !alt && !super && char_count > 0) {
    scroll_to_bottom(app);
  }
}

// ---------------------------------------------------------------------------
// Mouse input: forwarding to apps and local selection

mouse_tracking :: (app: *App) -> bool {
  tracking: bool;
  if ghostty_terminal_get(app.term, .MOUSE_TRACKING, *tracking) != .SUCCESS return false;
  return tracking;
}

current_mods :: () -> u16 {
  mods: u16 = 0;
  if IsKeyDown(RK_LEFT_SHIFT) || IsKeyDown(RK_RIGHT_SHIFT) mods |= GHOSTTY_MODS_SHIFT;
  if IsKeyDown(RK_LEFT_CONTROL) || IsKeyDown(RK_RIGHT_CONTROL) mods |= GHOSTTY_MODS_CTRL;
  if IsKeyDown(RK_LEFT_ALT) || IsKeyDown(RK_RIGHT_ALT) mods |= GHOSTTY_MODS_ALT;
  if IsKeyDown(RK_LEFT_SUPER) || IsKeyDown(RK_RIGHT_SUPER) mods |= GHOSTTY_MODS_SUPER;
  return mods;
}

send_mouse :: (app: *App, action: GhosttyMouseAction, button: GhosttyMouseButton,
               has_button: bool, pos: Vector2) {
  ghostty_mouse_encoder_set_from_terminal(app.mouse_enc, app.term);

  size: GhosttyMouseEncoderSize;
  size.size = cast(u64) size_of(GhosttyMouseEncoderSize);
  size.screen_width = cast(u32) GetScreenWidth();
  size.screen_height = cast(u32) GetScreenHeight();
  size.cell_width = cast(u32) (app.cell_w + 0.5);
  size.cell_height = cast(u32) (app.cell_h + 0.5);
  size.padding_top = cast(u32) app.pad_y;
  size.padding_bottom = cast(u32) app.pad_y;
  size.padding_left = cast(u32) app.pad_x;
  size.padding_right = cast(u32) app.pad_x;
  ghostty_mouse_encoder_set(app.mouse_enc, .SIZE, *size);

  any := IsMouseButtonDown(RM_LEFT) || IsMouseButtonDown(RM_RIGHT) || IsMouseButtonDown(RM_MIDDLE);
  ghostty_mouse_encoder_set(app.mouse_enc, .ANY_BUTTON_PRESSED, *any);

  ghostty_mouse_event_set_action(app.mouse_event, action);
  if has_button ghostty_mouse_event_set_button(app.mouse_event, button);
  else ghostty_mouse_event_clear_button(app.mouse_event);
  ghostty_mouse_event_set_mods(app.mouse_event, current_mods());
  ghostty_mouse_event_set_position(app.mouse_event, GhosttyMousePosition.{pos.x, pos.y});

  buf: [128] u8;
  written: u64;
  res := ghostty_mouse_encoder_encode(app.mouse_enc, app.mouse_event, buf.data, 128, *written);
  if res == .SUCCESS && written > 0 {
    write_pty(app, buf.data, written);
  }
}

mouse_to_cell :: (app: *App, pos: Vector2, col: *s32, row: *s32) -> bool {
  if pos.x < app.pad_x || pos.y < app.pad_y return false;
  x := cast(s32) ((pos.x - app.pad_x) / app.cell_w);
  y := cast(s32) ((pos.y - app.pad_y) / app.cell_h);
  if x < 0 || y < 0 || x >= cast(s32) app.cols || y >= cast(s32) app.rows return false;
  col.* = x;
  row.* = y;
  return true;
}

grid_ref_at :: (app: *App, col: s32, row: s32, ref: *GhosttyGridRef) -> bool {
  pt: GhosttyPoint;
  pt.tag = .VIEWPORT;
  pt.value.coordinate.x = cast(u16) col;
  pt.value.coordinate.y = cast(u32) row;
  return ghostty_terminal_grid_ref(app.term, pt, ref) == .SUCCESS;
}

install_selection :: (app: *App, sel: *GhosttySelection) {
  ghostty_terminal_set(app.term, .SELECTION, sel);
}

selection_geometry :: (app: *App, geo: *GhosttySelectionGestureGeometry) {
  geo.columns = cast(u32) app.cols;
  geo.cell_width = cast(u32) (app.cell_w + 0.5);
  geo.padding_left = cast(u32) app.pad_x;
  geo.screen_height = cast(u32) GetScreenHeight();
}

selection_press :: (app: *App, pos: Vector2, col: s32, row: s32) {
  ref: GhosttyGridRef;
  if !grid_ref_at(app, col, row, *ref) return;

  ghostty_selection_gesture_event_set(app.sel_press, .REF, *ref);
  sp: GhosttySurfacePosition;
  sp.x = pos.x;
  sp.y = pos.y;
  ghostty_selection_gesture_event_set(app.sel_press, .POSITION, *sp);
  now: u64 = cast(u64) (GetTime() * 1_000_000_000.0);
  ghostty_selection_gesture_event_set(app.sel_press, .TIME_NS, *now);
  interval: u64 = 400_000_000;
  ghostty_selection_gesture_event_set(app.sel_press, .REPEAT_INTERVAL_NS, *interval);
  dist: float64 = 6.0;
  ghostty_selection_gesture_event_set(app.sel_press, .REPEAT_DISTANCE, *dist);

  sel: GhosttySelection;
  if ghostty_selection_gesture_event(app.sel_gesture, app.term, app.sel_press, *sel) == .SUCCESS {
    install_selection(app, *sel);
  }
  app.sel_dragging = true;
}

selection_drag :: (app: *App, pos: Vector2, col: s32, row: s32) {
  ref: GhosttyGridRef;
  if !grid_ref_at(app, col, row, *ref) return;
  ghostty_selection_gesture_event_set(app.sel_drag, .REF, *ref);
  geo: GhosttySelectionGestureGeometry;
  selection_geometry(app, *geo);
  ghostty_selection_gesture_event_set(app.sel_drag, .GEOMETRY, *geo);
  sp: GhosttySurfacePosition;
  sp.x = pos.x;
  sp.y = pos.y;
  ghostty_selection_gesture_event_set(app.sel_drag, .POSITION, *sp);
  rect := IsKeyDown(RK_LEFT_ALT) || IsKeyDown(RK_RIGHT_ALT);
  ghostty_selection_gesture_event_set(app.sel_drag, .RECTANGLE, *rect);

  sel: GhosttySelection;
  if ghostty_selection_gesture_event(app.sel_gesture, app.term, app.sel_drag, *sel) == .SUCCESS {
    install_selection(app, *sel);
  }
}

selection_release :: (app: *App, pos: Vector2) {
  col: s32; row: s32;
  ref: GhosttyGridRef;
  if mouse_to_cell(app, pos, *col, *row) && grid_ref_at(app, col, row, *ref) {
    ghostty_selection_gesture_event_set(app.sel_release, .REF, *ref);
  } else {
    ghostty_selection_gesture_event_set(app.sel_release, .REF, null);
  }
  ghostty_selection_gesture_event(app.sel_gesture, app.term, app.sel_release, null);
  app.sel_dragging = false;

  // A plain single click (no drag, no double/triple click) clears the
  // selection, so clicking anywhere deselects.
  dragged: bool;
  click_count: u8;
  if ghostty_selection_gesture_get(app.sel_gesture, app.term, .DRAGGED, *dragged) == .SUCCESS &&
     ghostty_selection_gesture_get(app.sel_gesture, app.term, .CLICK_COUNT, *click_count) == .SUCCESS {
    if !dragged && click_count == 1 {
      ghostty_terminal_set(app.term, .SELECTION, null);
    }
  }
}

handle_local_mouse :: (app: *App, pos: Vector2, wheel: float) {
  if wheel != 0.0 scroll_viewport(app, -cast(s64) (wheel * 3.0));

  col: s32; row: s32;
  inside := mouse_to_cell(app, pos, *col, *row);

  if IsMouseButtonPressed(RM_LEFT) {
    if inside {
      selection_press(app, pos, col, row);
    } else {
      ghostty_terminal_set(app.term, .SELECTION, null);
      ghostty_selection_gesture_reset(app.sel_gesture, app.term);
      app.sel_dragging = false;
    }
  }
  if app.sel_dragging && IsMouseButtonDown(RM_LEFT) && inside {
    selection_drag(app, pos, col, row);
  }
  if IsMouseButtonReleased(RM_LEFT) {
    selection_release(app, pos);
  }
}

handle_forwarded_mouse :: (app: *App, pos: Vector2, wheel: float) {
  if IsMouseButtonPressed(RM_LEFT)
    send_mouse(app, .PRESS, .LEFT, true, pos);
  if IsMouseButtonReleased(RM_LEFT)
    send_mouse(app, .RELEASE, .LEFT, true, pos);
  if IsMouseButtonPressed(RM_RIGHT)
    send_mouse(app, .PRESS, .RIGHT, true, pos);
  if IsMouseButtonReleased(RM_RIGHT)
    send_mouse(app, .RELEASE, .RIGHT, true, pos);
  if IsMouseButtonPressed(RM_MIDDLE)
    send_mouse(app, .PRESS, .MIDDLE, true, pos);
  if IsMouseButtonReleased(RM_MIDDLE)
    send_mouse(app, .RELEASE, .MIDDLE, true, pos);

  if wheel != 0.0 {
    button: GhosttyMouseButton = ifx wheel > 0.0 then .FOUR else .FIVE;
    mag := ifx wheel < 0.0 then -wheel else wheel;
    count := cast(s32) mag;
    if count < 1 count = 1;
    for i: 0..count-1 {
      send_mouse(app, .PRESS, button, true, pos);
      send_mouse(app, .RELEASE, button, true, pos);
    }
  }

  delta := GetMouseDelta();
  if delta.x != 0.0 || delta.y != 0.0 {
    button: GhosttyMouseButton = .LEFT;
    has := false;
    if IsMouseButtonDown(RM_LEFT) { button = .LEFT; has = true; }
    else if IsMouseButtonDown(RM_RIGHT) { button = .RIGHT; has = true; }
    else if IsMouseButtonDown(RM_MIDDLE) { button = .MIDDLE; has = true; }
    send_mouse(app, .MOTION, button, has, pos);
  }
}

handle_mouse :: (app: *App) {
  wheel := GetMouseWheelMove();
  pos := GetMousePosition();
  shift := IsKeyDown(RK_LEFT_SHIFT) || IsKeyDown(RK_RIGHT_SHIFT);
  if mouse_tracking(app) && !shift {
    handle_forwarded_mouse(app, pos, wheel);
  } else {
    handle_local_mouse(app, pos, wheel);
  }
}

// ---------------------------------------------------------------------------
// Rendering

raylib_color :: (c: GhosttyColorRgb) -> Color {
  return Color.{c.r, c.g, c.b, 255};
}

set_color_alpha :: (c: Color, a: u8) -> Color {
  return Color.{c.r, c.g, c.b, a};
}

WHITE_COLOR :: Color.{255, 255, 255, 255};
SELECTION_COLOR :: Color.{76, 120, 196, 135};

get_default_colors :: (app: *App, bg: *GhosttyColorRgb, fg: *GhosttyColorRgb) {
  colors: GhosttyRenderStateColors;
  colors.size = cast(u64) size_of(GhosttyRenderStateColors);
  if ghostty_render_state_get(app.render, .COLORS, *colors) == .SUCCESS {
    bg.* = colors.background;
    fg.* = colors.foreground;
  } else {
    bg.* = GhosttyColorRgb.{0, 0, 0};
    fg.* = GhosttyColorRgb.{220, 220, 220};
  }
}

layout :: (app: *App) {
  sw := cast(float) GetScreenWidth();
  sh := cast(float) GetScreenHeight();

  cols := cast(u16) max(1, cast(s32) ((sw - app.pad_x * 2) / app.cell_w));
  rows := cast(u16) max(1, cast(s32) ((sh - app.pad_y * 2) / app.cell_h));

  if cols == app.cols && rows == app.rows return;

  app.cols = cols;
  app.rows = rows;
  ghostty_terminal_resize(app.term, cols, rows,
    cast(u32) (app.cell_w + 0.5), cast(u32) (app.cell_h + 0.5));
  set_pty_size(app);
}

update_title :: (app: *App) {
  title: GhosttyString;
  if ghostty_terminal_get(app.term, .TITLE, *title) != .SUCCESS return;
  if title.len == 0 || title.len >= app.title_buf.count return;
  if title.len == app.title_len {
    same := true;
    for i: 0..title.len-1 {
      if title.ptr[i] != app.title_buf[i] { same = false; break; }
    }
    if same return;
  }
  for i: 0..title.len app.title_buf[i] = title.ptr[i];
  app.title_buf[title.len] = 0;
  app.title_len = title.len;
  SetWindowTitle(cast(*u8) app.title_buf.data);
}

// One visible cell, with everything already resolved for drawing.
CellVis :: struct {
  x:         s32;
  text:      [128] u8;
  text_len:  u64;
  has_text:  bool;
  wide:      bool;
  face:      s32;
  fg:        Color;
  bg:        Color;
  has_bg:    bool;
  bold:      bool;
  faint:     bool;
  underline: bool;
  strike:    bool;
  selected:  bool;
}

collect_row :: (app: *App, cursor_x: s32, cursor_y: s32, cursor_block: bool,
                cursor_color: Color, bg_color: Color, fg_color: Color,
                viewport_y: s32, row: *[MAX_COLS] CellVis, count: *s32) {
  count.* = 0;
  x: s32 = 0;
  while ghostty_render_state_row_cells_next(app.cells) {
    if x >= cast(s32) app.cols break;
    if count.* >= row.count break;

    cv := *row.*[count.*];
    cv.* = CellVis.{};
    cv.x = x;

    text: GhosttyBuffer;
    text.ptr = cv.text.data;
    text.cap = cv.text.count - 1;
    text.len = 0;
    if ghostty_render_state_row_cells_get(app.cells, .GRAPHEMES_UTF8, *text) == .SUCCESS {
      if text.len > 0 {
        cv.text[text.len] = 0;
        cv.text_len = text.len;
        cv.has_text = true;
        cv.face = pick_face_utf8(*app.text, cv.text.data, cv.text_len);
        cv.wide = cell_text_width(cv.text.data, cv.text_len) == 2;
      }
    }
    if cv.face == 0 && !cv.has_text cv.face = -1;

    cv.bg = bg_color;
    cv.fg = fg_color;

    style: GhosttyStyle;
    styled := ghostty_render_state_row_cells_get(app.cells, .STYLE, *style) == .SUCCESS;
    if styled {
      cv.bold = (style.flags & GHOSTTY_STYLE_FLAG_BOLD) != 0;
      inverse := (style.flags & GHOSTTY_STYLE_FLAG_INVERSE) != 0;
      cv.faint = (style.flags & GHOSTTY_STYLE_FLAG_FAINT) != 0;
      cv.underline = (style.flags & GHOSTTY_STYLE_UNDERLINE_MASK) != 0;
      cv.strike = (style.flags & GHOSTTY_STYLE_FLAG_STRIKETHROUGH) != 0;

      bg_rgb: GhosttyColorRgb;
      if ghostty_render_state_row_cells_get(app.cells, .BG_COLOR, *bg_rgb) == .SUCCESS {
        cv.bg = raylib_color(bg_rgb);
        cv.has_bg = true;
      }
      fg_rgb: GhosttyColorRgb;
      if ghostty_render_state_row_cells_get(app.cells, .FG_COLOR, *fg_rgb) == .SUCCESS {
        cv.fg = raylib_color(fg_rgb);
      }
      if inverse {
        t := cv.fg;
        cv.fg = cv.bg;
        cv.bg = t;
        cv.has_bg = true;
      }
    }

    selected: bool;
    if ghostty_render_state_row_cells_get(app.cells, .SELECTED, *selected) == .SUCCESS {
      cv.selected = selected;
    }

    if cv.faint cv.fg = set_color_alpha(cv.fg, 150);

    if cursor_block && cursor_x == x && cursor_y == viewport_y {
      cv.bg = cursor_color;
      cv.fg = bg_color;
      cv.has_bg = true;
      cv.selected = false;
    }

    count.* += 1;
    x += 1;
  }
}

draw_row_backgrounds :: (app: *App, row: *[MAX_COLS] CellVis, count: s32, viewport_y: s32) {
  for i: 0..count-1 {
    cv := *row.*[i];
    cx := app.pad_x + cast(float) cv.x * app.cell_w;
    cy := app.pad_y + cast(float) viewport_y * app.cell_h;
    w := cast(s32) (app.cell_w + 0.5);
    h := cast(s32) (app.cell_h + 0.5);
    if cv.has_bg DrawRectangle(cast(s32) (cx + 0.5), cast(s32) (cy + 0.5), w, h, cv.bg);
    if cv.selected DrawRectangle(cast(s32) (cx + 0.5), cast(s32) (cy + 0.5), w, h, SELECTION_COLOR);
  }
}

draw_glyph :: (app: *App, g: *GlyphEntry, x: float, y: float, color: Color, bold: bool) {
  if g.tex.id == 0 || g.w <= 0 || g.h <= 0 return;
  tint := ifx g.color then WHITE_COLOR else color;
  src := Rectangle.{0.0, 0.0, cast(float) g.w, cast(float) g.h};
  dst := Rectangle.{x, y, cast(float) g.w, cast(float) g.h};
  DrawTexturePro(g.tex, src, dst, Vector2.{0.0, 0.0}, 0.0, tint);
  if bold && !g.color {
    DrawTexturePro(g.tex, src,
      Rectangle.{x + 0.7, y, cast(float) g.w, cast(float) g.h},
      Vector2.{0.0, 0.0}, 0.0, tint);
  }
}

draw_scaled_glyph :: (app: *App, g: *GlyphEntry, x: float, y: float,
                      target_w: float, target_h: float, color: Color) {
  if g.tex.id == 0 || g.w <= 0 || g.h <= 0 return;
  scale_x := target_w / cast(float) g.w;
  scale_y := target_h / cast(float) g.h;
  scale := min(scale_x, scale_y);
  dw := cast(float) g.w * scale;
  dh := cast(float) g.h * scale;
  dx := x + (target_w - dw) * 0.5;
  dy := y + (target_h - dh) * 0.5;
  tint := ifx g.color then WHITE_COLOR else color;
  DrawTexturePro(g.tex, Rectangle.{0.0, 0.0, cast(float) g.w, cast(float) g.h},
    Rectangle.{dx, dy, dw, dh}, Vector2.{0.0, 0.0}, 0.0, tint);
}

// Draw one cell whose grapheme is wide or comes from the emoji face. These
// are not grouped into ligature runs; they are scaled into their cell box.
draw_wide_cell :: (app: *App, cv: *CellVis, cell_y: float) {
  if !cv.has_text || cv.face < 0 return;
  cps: [32] u32;
  n := utf8_decode(cv.text.data, cv.text_len, *cps);
  if n <= 0 return;

  face := *app.text.faces[cv.face];
  hb_buffer_clear_contents(app.text.hb_buf);
  hb_buffer_add_utf8(app.text.hb_buf, cv.text.data, cast(s32) cv.text_len, 0, cast(s32) cv.text_len);
  hb_buffer_guess_segment_properties(app.text.hb_buf);
  hb_shape(face.hb, app.text.hb_buf, null, 0);

  length: u32;
  infos := hb_buffer_get_glyph_infos(app.text.hb_buf, *length);
  if infos == null || length == 0 return;

  g := TextEngine_glyph(*app.text, cv.face, infos[0].codepoint);
  target_w := ifx cv.wide then app.cell_w * 2.0 else app.cell_w;
  cx := app.pad_x + cast(float) cv.x * app.cell_w;
  draw_scaled_glyph(app, g, cx, cell_y, target_w, app.cell_h, cv.fg);
}

// Shape a run of adjacent single-width cells and draw its glyphs.
draw_shaped_run :: (app: *App, start_col: s32, cell_y: float, text: *u8, len: u64,
                    starts: *[MAX_COLS] u64, cell_count: s32, face_index: s32,
                    color: Color, bold: bool) {
  if len == 0 || cell_count <= 0 return;
  face := *app.text.faces[face_index];
  hb_buffer_clear_contents(app.text.hb_buf);
  hb_buffer_add_utf8(app.text.hb_buf, text, cast(s32) len, 0, cast(s32) len);
  hb_buffer_guess_segment_properties(app.text.hb_buf);
  hb_shape(face.hb, app.text.hb_buf, null, 0);

  length: u32;
  infos := hb_buffer_get_glyph_infos(app.text.hb_buf, *length);
  positions := hb_buffer_get_glyph_positions(app.text.hb_buf, null);
  if infos == null || positions == null return;

  base_x := app.pad_x + cast(float) start_col * app.cell_w;
  j := 0;
  for i: 0..cast(s32) length-1 {
    cluster := infos[i].cluster;
    while j + 1 < cell_count && cluster >= starts.*[j + 1] j += 1;
    if j >= cell_count j = cell_count - 1;

    g := TextEngine_glyph(*app.text, face_index, infos[i].codepoint);
    x := base_x + cast(float) j * app.cell_w +
         cast(float) positions[i].x_offset / 64.0 + cast(float) g.left;
    y := app.baseline + cell_y -
         cast(float) positions[i].y_offset / 64.0 - cast(float) g.top;
    draw_glyph(app, g, x, y, color, bold);
  }
}

draw_row_text :: (app: *App, row: *[MAX_COLS] CellVis, count: s32, viewport_y: s32) {
  cell_y := app.pad_y + cast(float) viewport_y * app.cell_h;

  run_text: [8192] u8;
  run_starts: [MAX_COLS] u64;
  i: s32 = 0;
  while i < count {
    cv := *row.*[i];
    if !cv.has_text { i += 1; continue; }

    if cv.wide || cv.face == app.text.emoji {
      draw_wide_cell(app, cv, cell_y);
      i += 1;
      continue;
    }

    // Group consecutive cells that share a face and text style. This is what
    // lets HarfBuzz form programming ligatures across cells.
    start_i := i;
    run_len: u64 = 0;
    cell_count: s32 = 0;
    start_x := cv.x;
    face := cv.face;
    fg := cv.fg;
    bold := cv.bold;

    while i < count {
      c := *row.*[i];
      if !c.has_text || c.wide || c.face != face ||
         c.x != start_x + cell_count { break; }
      if c.fg.r != fg.r || c.fg.g != fg.g || c.fg.b != fg.b || c.fg.a != fg.a ||
         c.bold != bold {
        break;
      }
      if run_len + c.text_len >= run_text.count break;
      run_starts[cell_count] = run_len;
      for k: 0..c.text_len-1 run_text[run_len + k] = c.text[k];
      run_len += c.text_len;
      cell_count += 1;
      i += 1;
    }
    run_starts[cell_count] = run_len;

    if cell_count > 0 {
      draw_shaped_run(app, start_x, cell_y, run_text.data, run_len,
        *run_starts, cell_count, face, fg, bold);
    } else {
      i += 1;
    }
  }

  for i: 0..count-1 {
    cv := *row.*[i];
    cx := app.pad_x + cast(float) cv.x * app.cell_w;
    if cv.underline {
      DrawRectangle(cast(s32) (cx + 0.5), cast(s32) (cell_y + app.cell_h - 2.0),
        cast(s32) (app.cell_w + 0.5), 1, cv.fg);
    }
    if cv.strike {
      DrawRectangle(cast(s32) (cx + 0.5), cast(s32) (cell_y + app.cell_h * 0.5),
        cast(s32) (app.cell_w + 0.5), 1, cv.fg);
    }
  }
}

// ---------------------------------------------------------------------------
// Kitty graphics

collect_images :: (app: *App) {
  app.img_count = 0;
  if ghostty_render_state_get(app.render, .IMAGE_ITERATOR, *app.img_iter) != .SUCCESS return;

  while ghostty_render_state_image_iterator_next(app.img_iter) {
    if app.img_count >= MAX_IMAGE_PLACEMENTS break;
    p := *app.img_placements[app.img_count];
    p.* = ImagePlacement.{};

    protocol: u32;
    if ghostty_render_state_image_get(app.img_iter, .PROTOCOL, *protocol) != .SUCCESS continue;
    if protocol != cast(u32) GhosttyImageProtocol.KITTY continue;

    ghostty_render_state_image_get(app.img_iter, .IMAGE_ID, *p.image_id);
    ghostty_render_state_image_get(app.img_iter, .IMAGE_GENERATION, *p.generation);
    ghostty_render_state_image_get(app.img_iter, .LAYER, *p.layer);
    ghostty_render_state_image_get(app.img_iter, .Z, *p.z);
    ghostty_render_state_image_get(app.img_iter, .VIEWPORT_COL, *p.col);
    ghostty_render_state_image_get(app.img_iter, .VIEWPORT_ROW, *p.row);
    ghostty_render_state_image_get(app.img_iter, .CELL_OFFSET_X, *p.offset_x);
    ghostty_render_state_image_get(app.img_iter, .CELL_OFFSET_Y, *p.offset_y);
    ghostty_render_state_image_get(app.img_iter, .PIXEL_WIDTH, *p.pixel_w);
    ghostty_render_state_image_get(app.img_iter, .PIXEL_HEIGHT, *p.pixel_h);
    ghostty_render_state_image_get(app.img_iter, .SOURCE_X, *p.source_x);
    ghostty_render_state_image_get(app.img_iter, .SOURCE_Y, *p.source_y);
    ghostty_render_state_image_get(app.img_iter, .SOURCE_WIDTH, *p.source_w);
    ghostty_render_state_image_get(app.img_iter, .SOURCE_HEIGHT, *p.source_h);
    p.protocol = protocol;
    if p.pixel_w == 0 || p.pixel_h == 0 continue;
    app.img_count += 1;
  }

  // Draw order is layer first, then z-index.
  for i: 1..app.img_count-1 {
    v := *app.img_placements[i];
    j := i - 1;
    while j >= 0 {
      a := *app.img_placements[j];
      if a.layer < v.layer || (a.layer == v.layer && a.z <= v.z) break;
      app.img_placements[j + 1] = a;
      j -= 1;
    }
    app.img_placements[j + 1] = v;
  }
}

image_cache_find :: (app: *App, id: u32) -> *ImageCacheEntry {
  for i: 0..IMAGE_CACHE_CAP-1 {
    if app.img_cache[i].used && app.img_cache[i].id == id return *app.img_cache[i];
  }
  return null;
}

image_cache_slot :: (app: *App) -> *ImageCacheEntry {
  for i: 0..IMAGE_CACHE_CAP-1 {
    if !app.img_cache[i].used return *app.img_cache[i];
  }
  // Evict the least recently used entry.
  best := 0;
  for i: 1..IMAGE_CACHE_CAP-1 {
    if app.img_cache[i].last_used < app.img_cache[best].last_used best = i;
  }
  e := *app.img_cache[best];
  if e.tex.id != 0 UnloadTexture(e.tex);
  e.* = ImageCacheEntry.{};
  return e;
}

submit_image_texture :: (app: *App, id: u32, generation: u64) -> Texture2D {
  empty: Texture2D;
  graphics: GhosttyKittyGraphics;
  if ghostty_terminal_get(app.term, .KITTY_GRAPHICS, *graphics) != .SUCCESS return empty;
  if graphics == null return empty;

  image := ghostty_kitty_graphics_image(graphics, id);
  if image == null return empty;

  w: u32; h: u32;
  format: GhosttyKittyImageFormat;
  pixels: GhosttyString;
  if ghostty_kitty_graphics_image_get(image, .WIDTH, *w) != .SUCCESS return empty;
  if ghostty_kitty_graphics_image_get(image, .HEIGHT, *h) != .SUCCESS return empty;
  if ghostty_kitty_graphics_image_get(image, .FORMAT, *format) != .SUCCESS return empty;
  if ghostty_kitty_graphics_image_get(image, .PIXELS, *pixels) != .SUCCESS return empty;
  if w == 0 || h == 0 || pixels.ptr == null return empty;

  bpp: u64 = 4;
  if format == .RGB bpp = 3;
  else if format == .GRAY_ALPHA bpp = 2;
  else if format == .GRAY bpp = 1;
  expected := cast(u64) w * cast(u64) h * bpp;
  if pixels.len < expected return empty;

  // Reserve a cache slot now (pending), then copy the raw pixels and hand the
  // format conversion to the worker thread.
  e := image_cache_slot(app);
  e.used = true;
  e.id = id;
  e.generation = generation;
  e.w = cast(s32) w;
  e.h = cast(s32) h;
  e.tex.id = 0;
  e.last_used = app.frame;

  raw := malloc(expected);
  if raw == null return empty;
  memcpy(raw, pixels.ptr, expected);

  render_submit_image(raw, expected, format, cast(s32) w, cast(s32) h, id, generation);
  return empty;
}

get_image_texture :: (app: *App, id: u32, generation: u64) -> Texture2D {
  e := image_cache_find(app, id);
  if e != null {
    if e.generation == generation {
      e.last_used = app.frame;
      return e.tex;
    }
    if e.tex.id != 0 UnloadTexture(e.tex);
    e.* = ImageCacheEntry.{};
  }
  return submit_image_texture(app, id, generation);
}

draw_images :: (app: *App, layer: u32) {
  for i: 0..app.img_count-1 {
    p := app.img_placements[i];
    if p.layer != layer continue;
    tex := get_image_texture(app, p.image_id, p.generation);
    if tex.id == 0 continue;

    src_x := cast(float) p.source_x;
    src_y := cast(float) p.source_y;
    src_w := ifx p.source_w > 0 then cast(float) p.source_w else cast(float) tex.width;
    src_h := ifx p.source_h > 0 then cast(float) p.source_h else cast(float) tex.height;
    dst_x := app.pad_x + cast(float) p.col * app.cell_w + cast(float) p.offset_x;
    dst_y := app.pad_y + cast(float) p.row * app.cell_h + cast(float) p.offset_y;
    DrawTexturePro(tex, Rectangle.{src_x, src_y, src_w, src_h},
      Rectangle.{dst_x, dst_y, cast(float) p.pixel_w, cast(float) p.pixel_h},
      Vector2.{0.0, 0.0}, 0.0, WHITE_COLOR);
  }
}

// ---------------------------------------------------------------------------
// Frame

render_terminal :: (app: *App) {
  if ghostty_render_state_update(app.render, app.term) != .SUCCESS return;

  // Advance animations before reading placements.
  graphics: GhosttyKittyGraphics;
  if ghostty_terminal_get(app.term, .KITTY_GRAPHICS, *graphics) == .SUCCESS && graphics != null {
    next_ms: u64;
    ghostty_kitty_graphics_animation_tick(graphics,
      cast(u64) (GetTime() * 1000.0), *next_ms);
  }

  // Upload any emoji / image rasterization the worker has finished.
  render_poll(*app.text, app);

  bg: GhosttyColorRgb;
  fg: GhosttyColorRgb;
  get_default_colors(app, *bg, *fg);
  bg_color := raylib_color(bg);
  fg_color := raylib_color(fg);

  ClearBackground(bg_color);

  cur: GhosttyRenderStateCursor;
  cur.size = cast(u64) size_of(GhosttyRenderStateCursor);
  have_cursor := ghostty_render_state_get(app.render, .CURSOR, *cur) == .SUCCESS;
  cursor_color := fg_color;
  if have_cursor {
    c: GhosttyColorRgb;
    if ghostty_render_state_get(app.render, .COLOR_CURSOR, *c) == .SUCCESS {
      cursor_color = raylib_color(c);
    }
  }
  blink_on := true;
  if have_cursor && cur.blinking {
    blink_on = ((cast(s64) (GetTime() * 2.0)) & 1) == 0;
  }
  cursor_visible := have_cursor && cur.visible && cur.viewport_has_value && blink_on;
  cursor_block := cursor_visible && cur.visual_style == GhosttyCursorStyle.BLOCK;
  cursor_x := ifx have_cursor && cur.viewport_has_value then cast(s32) cur.viewport_x else -1;
  cursor_y := ifx have_cursor && cur.viewport_has_value then cast(s32) cur.viewport_y else -1;

  collect_images(app);

  sw := cast(s32) (app.pad_x + cast(float) app.cols * app.cell_w);
  sh := cast(s32) (app.pad_y + cast(float) app.rows * app.cell_h);
  BeginScissorMode(cast(s32) app.pad_x, cast(s32) app.pad_y,
    sw - cast(s32) app.pad_x, sh - cast(s32) app.pad_y);

  // Images below the cell backgrounds.
  draw_images(app, cast(u32) GhosttyImageLayer.BELOW_BACKGROUND);

  // Cell backgrounds and selection overlay.
  ghostty_render_state_get(app.render, .ROW_ITERATOR, *app.rows_iter);
  while ghostty_render_state_row_iterator_next(app.rows_iter) {
    viewport_y: s32;
    if ghostty_render_state_row_get(app.rows_iter, .VIEWPORT_Y, *viewport_y) != .SUCCESS continue;
    if viewport_y < 0 || viewport_y >= cast(s32) app.rows continue;
    if ghostty_render_state_row_get(app.rows_iter, .CELLS, *app.cells) != .SUCCESS continue;

    row: [MAX_COLS] CellVis;
    count: s32;
    collect_row(app, cursor_x, cursor_y, cursor_block, cursor_color,
      bg_color, fg_color, viewport_y, *row, *count);
    draw_row_backgrounds(app, *row, count, viewport_y);
  }

  // Images between the backgrounds and the text.
  draw_images(app, cast(u32) GhosttyImageLayer.BELOW_TEXT);

  // Text.
  ghostty_render_state_get(app.render, .ROW_ITERATOR, *app.rows_iter);
  while ghostty_render_state_row_iterator_next(app.rows_iter) {
    viewport_y: s32;
    if ghostty_render_state_row_get(app.rows_iter, .VIEWPORT_Y, *viewport_y) != .SUCCESS continue;
    if viewport_y < 0 || viewport_y >= cast(s32) app.rows continue;
    if ghostty_render_state_row_get(app.rows_iter, .CELLS, *app.cells) != .SUCCESS continue;

    row: [MAX_COLS] CellVis;
    count: s32;
    collect_row(app, cursor_x, cursor_y, cursor_block, cursor_color,
      bg_color, fg_color, viewport_y, *row, *count);
    draw_row_text(app, *row, count, viewport_y);
  }

  // Images above the text.
  draw_images(app, cast(u32) GhosttyImageLayer.ABOVE_TEXT);

  EndScissorMode();

  // Non-block cursor shapes.
  if cursor_visible && !cursor_block {
    cx := app.pad_x + cast(float) cur.viewport_x * app.cell_w;
    cy := app.pad_y + cast(float) cur.viewport_y * app.cell_h;
    if cur.visual_style == GhosttyCursorStyle.BAR {
      DrawRectangle(cast(s32) (cx + 0.5), cast(s32) (cy + 0.5), 2,
        cast(s32) (app.cell_h + 0.5), cursor_color);
    } else if cur.visual_style == GhosttyCursorStyle.UNDERLINE {
      DrawRectangle(cast(s32) (cx + 0.5), cast(s32) (cy + app.cell_h - 2.0),
        cast(s32) (app.cell_w + 0.5), 2, cursor_color);
    } else if cur.visual_style == GhosttyCursorStyle.BLOCK_HOLLOW {
      DrawRectangleLines(cast(s32) (cx + 0.5), cast(s32) (cy + 0.5),
        cast(s32) (app.cell_w + 0.5), cast(s32) (app.cell_h + 0.5), cursor_color);
    }
  }
}

// ---------------------------------------------------------------------------
// Configuration (dix)

cstr_to_string :: (s: *u8) -> string {
  return string.{cast(s64) strlen(s), s};
}

config_path :: (buf: *[1024] u8) -> *u8 {
  dst := buf.data;
  n: u64 = 0;

  base := getenv("XDG_CONFIG_HOME");
  use_home := false;
  if base == null || base[0] == 0 {
    base = getenv("HOME");
    if base == null || base[0] == 0 return null;
    use_home = true;
  }

  blen := strlen(base);
  if blen + 32 >= buf.count return null;
  for i: 0..blen-1 dst[i] = base[i];
  n = blen;

  if use_home {
    suffix := "/.config";
    for i: 0..suffix.count-1 dst[n + cast(u64) i] = suffix.data[i];
    n += cast(u64) suffix.count;
  }

  tail := "/josh/config.dix";
  for i: 0..tail.count-1 dst[n + cast(u64) i] = tail.data[i];
  n += cast(u64) tail.count;
  dst[n] = 0;
  return dst;
}

read_color :: (dix: Dix, key: string, out: *GhosttyColorRgb) -> bool {
  s := get_dix_value(dix, string, key);
  if s == null return false;
  if ghostty_color_parse(s.data, cast(u64) s.count, out) == .SUCCESS return true;
  return false;
}

load_config :: (app: *App) {
  path: [1024] u8;
  p := config_path(*path);
  if p == null return;
  if !FileExists(p) return;

  dix, ok := load_dix_from_file(cstr_to_string(p));
  if !ok {
    print("Failed to parse config file: %\n", cstr_to_string(p));
    return;
  }

  // Custom font family.
  font := get_dix_value(dix, string, "font");
  if font != null && font.count > 0 && font.count < app.config.font.count {
    for i: 0..font.count-1 app.config.font[i] = font.data[i];
    app.config.font[font.count] = 0;
    app.config.has_font = true;
  }

  // Font size (accept either an integer or a float).
  fs := get_dix_value(dix, float, "font_size");
  if fs != null && fs.* > 0.0 {
    app.font_size = fs.*;
  } else {
    fsi := get_dix_value(dix, int, "font_size");
    if fsi != null && fsi.* > 0 app.font_size = cast(float) fsi.*;
  }

  // Terminal padding.
  px := get_dix_value(dix, int, "padding_x");
  if px != null && px.* >= 0 app.pad_x = cast(float) px.*;
  py := get_dix_value(dix, int, "padding_y");
  if py != null && py.* >= 0 app.pad_y = cast(float) py.*;

  // Custom colors.
  if read_color(dix, "background", *app.config.bg) app.config.has_bg = true;
  if read_color(dix, "foreground", *app.config.fg) app.config.has_fg = true;
  if read_color(dix, "cursor", *app.config.cursor) app.config.has_cursor = true;

  // 16-colour palette, read from a nested `palette` object.
  palette_keys: [16] string = .[
    "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
    "bright_black", "bright_red", "bright_green", "bright_yellow",
    "bright_blue", "bright_magenta", "bright_cyan", "bright_white",
  ];
  for i: 0..15 {
    s := get_dix_value(dix, string, "palette", palette_keys[i]);
    if s == null continue;
    c: GhosttyColorRgb;
    if ghostty_color_parse(s.data, cast(u64) s.count, *c) == .SUCCESS {
      app.config.palette[i] = c;
      app.config.has_palette[i] = true;
    }
  }
}

apply_config_colors :: (app: *App) {
  if app.config.has_bg    ghostty_terminal_set(app.term, .COLOR_BACKGROUND, *app.config.bg);
  if app.config.has_fg    ghostty_terminal_set(app.term, .COLOR_FOREGROUND, *app.config.fg);
  if app.config.has_cursor ghostty_terminal_set(app.term, .COLOR_CURSOR, *app.config.cursor);

  any_palette := false;
  for i: 0..15 if app.config.has_palette[i] { any_palette = true; break; }
  if any_palette {
    palette: [256] GhosttyColorRgb;
    ghostty_color_palette_default(palette.data);
    for i: 0..15 {
      if app.config.has_palette[i] palette[i] = app.config.palette[i];
    }
    ghostty_terminal_set(app.term, .COLOR_PALETTE, palette.data);
  }
}

main :: () {
  SetTraceLogLevel(5); // errors only
  init_key_list();

  app: App;
  app.master = -1;
  app.child_pid = -1;
  app.pad_x = 4.0;
  app.pad_y = 4.0;
  app.font_size = 20.0;

  if !spawn_shell(*app, 80, 24) {
    print("Failed to start a shell.\n");
    return;
  }

  if ghostty_terminal_new(null, *app.term, 80, 24) != .SUCCESS {
    print("Failed to create the ghostty terminal.\n");
    return;
  }

  max_lines: u64 = 10_000;
  ghostty_terminal_set(app.term, .SCROLLBACK_MAX_LINES, *max_lines);

  load_config(*app);
  apply_config_colors(*app);

  if ghostty_render_state_new(null, *app.render) != .SUCCESS ||
     ghostty_render_state_row_iterator_new(null, *app.rows_iter) != .SUCCESS ||
     ghostty_render_state_row_cells_new(null, *app.cells) != .SUCCESS ||
     ghostty_render_state_image_iterator_new(null, *app.img_iter) != .SUCCESS ||
     ghostty_key_event_new(null, *app.key_event) != .SUCCESS ||
     ghostty_key_encoder_new(null, *app.key_enc) != .SUCCESS ||
     ghostty_mouse_event_new(null, *app.mouse_event) != .SUCCESS ||
     ghostty_mouse_encoder_new(null, *app.mouse_enc) != .SUCCESS {
    print("Failed to create ghostty rendering/input state.\n");
    return;
  }

  if ghostty_selection_gesture_new(null, *app.sel_gesture) != .SUCCESS ||
     ghostty_selection_gesture_event_new(null, *app.sel_press, .PRESS) != .SUCCESS ||
     ghostty_selection_gesture_event_new(null, *app.sel_drag, .DRAG) != .SUCCESS ||
     ghostty_selection_gesture_event_new(null, *app.sel_release, .RELEASE) != .SUCCESS {
    print("Failed to create selection state.\n");
    return;
  }

  if ghostty_formatter_terminal_new(null, *app.formatter, app.term) != .SUCCESS {
    print("Failed to create the formatter.\n");
    return;
  }

  SetConfigFlags(cast(u32) ConfigFlags.FLAG_WINDOW_RESIZABLE);
  InitWindow(1200, 800, term_name);
  SetWindowMinSize(320, 200);
  SetTargetFPS(60);
  SetExitKey(0);

  font_override: *u8 = ifx app.config.has_font then app.config.font.data else null;
  if !TextEngine_init(*app.text, cast(s32) app.font_size, font_override) {
    print("Failed to initialize text rendering.\n");
    CloseWindow();
    return;
  }
  app.cell_w = app.text.cell_w;
  app.cell_h = app.font_size * 1.35;

  primary := *app.text.faces[app.text.primary];
  asc := primary.ascender;
  desc := primary.descender;
  app.baseline = (app.cell_h - (asc - desc)) * 0.5 + asc;

  // Start the rasterization worker (emoji + Kitty images).
  emoji_path: *u8 = ifx app.text.emoji >= 0 then app.text.emoji_path.data else null;
  if !render_worker_start(emoji_path, app.text.emoji_index) {
    print("Failed to start the rasterization worker.\n");
  }

  app.cols = 0;
  app.rows = 0;
  layout(*app);

  app.shot_path = getenv("JAI_TERM_SCREENSHOT");
  start_time := GetTime();

  // Optional startup command, mostly handy for demos and automated checks.
  command := getenv("JAI_TERM_COMMAND");
  if command != null && command[0] != 0 {
    len := strlen(command);
    write_pty(*app, command, len);
    write_pty(*app, "\r", 1);
  }

  while !WindowShouldClose() {
    app.frame += 1;
    handle_mouse(*app);
    handle_keyboard(*app);
    if pump_pty(*app) >= 0 {
      ghostty_key_encoder_set_from_terminal(app.key_enc, app.term);
      alt_esc: bool = true;
      ghostty_key_encoder_set(app.key_enc, .ALT_ESC_PREFIX, *alt_esc);
    }
    if app.child_dead break;

    layout(*app);
    update_title(*app);

    BeginDrawing();
    render_terminal(*app);
    EndDrawing();

    if app.shot_path != null && !app.shot_done && GetTime() - start_time > 1.5 {
      TakeScreenshot(app.shot_path);
      app.shot_done = true;
      if getenv("JAI_TERM_EXIT") != null break;
    }
  }

  if app.child_pid > 0 {
    close(app.master);
    kill(-app.child_pid, SIGHUP);
    kill(app.child_pid, SIGHUP);
  }

  render_worker_stop();

  // Text resources.
  for i: 0..GLYPH_CACHE_CAP-1 {
    if app.text.glyphs[i].used {
      if app.text.glyphs[i].tex.id != 0 UnloadTexture(app.text.glyphs[i].tex);
    }
  }
  for i: 0..IMAGE_CACHE_CAP-1 {
    if app.img_cache[i].used && app.img_cache[i].tex.id != 0 UnloadTexture(app.img_cache[i].tex);
  }
  for i: 0..app.text.face_count-1 {
    hb_font_destroy(app.text.faces[i].hb);
    FT_Done_Face(app.text.faces[i].ft);
  }
  hb_buffer_destroy(app.text.hb_buf);
  FT_Done_FreeType(app.text.lib);

  ghostty_formatter_free(app.formatter);
  ghostty_selection_gesture_event_free(app.sel_press);
  ghostty_selection_gesture_event_free(app.sel_drag);
  ghostty_selection_gesture_event_free(app.sel_release);
  ghostty_selection_gesture_free(app.sel_gesture, app.term);
  ghostty_mouse_encoder_free(app.mouse_enc);
  ghostty_mouse_event_free(app.mouse_event);
  ghostty_key_encoder_free(app.key_enc);
  ghostty_key_event_free(app.key_event);
  ghostty_render_state_image_iterator_free(app.img_iter);
  ghostty_render_state_row_cells_free(app.cells);
  ghostty_render_state_row_iterator_free(app.rows_iter);
  ghostty_render_state_free(app.render);
  ghostty_terminal_free(app.term);
  CloseWindow();
}

term_name :: "josh";

#load "src/fontconfig.jai";
#load "src/libc.jai";
#load "src/render.jai";

#import "Basic";
#import "POSIX";
#import "Raylib";
#import "libghostty-vt-jai";
#import "dix";
