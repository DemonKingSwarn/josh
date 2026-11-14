freetype :: #library,system "libfreetype";
harfbuzz :: #library,system "libharfbuzz";
fontconfig :: #library,system "libfontconfig";
librsvg :: #library,system "librsvg-2";
libcairo :: #library,system "libcairo";


FT_Generic :: struct {
  data:      *void;
  finalizer: *void;
}

FT_BBox :: struct {
  x_min: s64;
  y_min: s64;
  x_max: s64;
  y_max: s64;
}

FT_Vector :: struct {
  x: s64;
  y: s64;
}

FT_Glyph_Metrics :: struct {
  width:        s64;
  height:       s64;
  horiBearingX: s64;
  horiBearingY: s64;
  horiAdvance:  s64;
  vertBearingX: s64;
  vertBearingY: s64;
  vertAdvance:  s64;
}

FT_Bitmap :: struct {
  rows:         u32;
  width:        u32;
  pitch:        s32;
  buffer:       *u8;
  num_grays:    u16;
  pixel_mode:   u8;
  palette_mode: u8;
  palette:      *void;
}

FT_FaceRec :: struct {
  num_faces:           s64;
  face_index:          s64;
  face_flags:          s64;
  style_flags:         s64;
  num_glyphs:          s64;
  family_name:         *u8;
  style_name:          *u8;
  num_fixed_sizes:     s32;
  available_sizes:     *void;
  num_charmaps:        s32;
  charmaps:            *void;
  generic:             FT_Generic;
  bbox:                FT_BBox;
  units_per_EM:        u16;
  ascender:            s16;
  descender:           s16;
  height:              s16;
  max_advance_width:   s16;
  max_advance_height:  s16;
  underline_position:  s16;
  underline_thickness: s16;
  glyph:               *FT_GlyphSlotRec;
  size:                *void;
  charmap:             *void;
}

FT_GlyphSlotRec :: struct {
  library:      *void;
  face:         *FT_FaceRec;
  next:         *FT_GlyphSlotRec;
  glyph_index:  u32;
  generic:      FT_Generic;
  metrics:      FT_Glyph_Metrics;
  linear_hori:  s64;
  linear_vert:  s64;
  advance:      FT_Vector;
  format:       u32;
  bitmap:       FT_Bitmap;
  bitmap_left:  s32;
  bitmap_top:   s32;
}

FT_Init_FreeType      :: (library: **void) -> s32 #foreign freetype;
FT_Done_FreeType      :: (library: *void) -> s32 #foreign freetype;
FT_New_Face           :: (library: *void, path: *u8, index: s64, face: **FT_FaceRec) -> s32 #foreign freetype;
FT_Done_Face          :: (face: *FT_FaceRec) -> s32 #foreign freetype;
FT_Set_Pixel_Sizes    :: (face: *FT_FaceRec, width: u32, height: u32) -> s32 #foreign freetype;
FT_Select_Size        :: (face: *FT_FaceRec, index: s32) -> s32 #foreign freetype;
FT_Get_Char_Index     :: (face: *FT_FaceRec, codepoint: u64) -> u32 #foreign freetype;
FT_Load_Glyph         :: (face: *FT_FaceRec, glyph: u32, flags: s32) -> s32 #foreign freetype;
FT_Render_Glyph       :: (slot: *FT_GlyphSlotRec, render_mode: s32) -> s32 #foreign freetype;

// Cairo (used to rasterize OT-SVG colour emoji through librsvg).
cairo_image_surface_create     :: (format: s32, width: s32, height: s32) -> *void #foreign libcairo;
cairo_create                   :: (surface: *void) -> *void #foreign libcairo;
cairo_scale                    :: (cr: *void, sx: float64, sy: float64) -> void #foreign libcairo;
cairo_translate                :: (cr: *void, tx: float64, ty: float64) -> void #foreign libcairo;
cairo_destroy                  :: (cr: *void) -> void #foreign libcairo;
cairo_surface_destroy          :: (surface: *void) -> void #foreign libcairo;
cairo_image_surface_get_data   :: (surface: *void) -> *u8 #foreign libcairo;
cairo_image_surface_get_stride :: (surface: *void) -> s32 #foreign libcairo;

// librsvg (renders the SVG documents embedded in OT-SVG emoji fonts).
RsvgDimensionData :: struct {
  width:  s32;
  height: s32;
  em:     float64;
  ex:     float64;
}

rsvg_handle_new_from_data :: (data: *u8, len: u64, error: **void) -> *void #foreign librsvg;
rsvg_handle_get_dimensions :: (handle: *void, dim: *RsvgDimensionData) -> void #foreign librsvg;
rsvg_handle_render_cairo   :: (handle: *void, cr: *void) -> s32 #foreign librsvg;
rsvg_handle_render_cairo_sub :: (handle: *void, cr: *void, id: *u8) -> s32 #foreign librsvg;
rsvg_handle_free           :: (handle: *void) -> void #foreign librsvg;

HbGlyphInfo :: struct {
  codepoint: u32;
  mask:      u32;
  cluster:   u32;
  var1:      u32;
  var2:      u32;
}

HbGlyphPosition :: struct {
  x_advance: s32;
  y_advance: s32;
  x_offset:  s32;
  y_offset:  s32;
  var:       s32;
}

hb_blob_create_from_file        :: (path: *u8) -> *void #foreign harfbuzz;
hb_blob_destroy                 :: (blob: *void) -> void #foreign harfbuzz;
hb_face_create                  :: (blob: *void, index: u32) -> *void #foreign harfbuzz;
hb_face_destroy                 :: (face: *void) -> void #foreign harfbuzz;
hb_font_create                  :: (face: *void) -> *void #foreign harfbuzz;
hb_font_destroy                 :: (font: *void) -> void #foreign harfbuzz;
hb_font_set_scale               :: (font: *void, x: s32, y: s32) -> void #foreign harfbuzz;
hb_buffer_create                :: () -> *void #foreign harfbuzz;
hb_buffer_destroy               :: (buffer: *void) -> void #foreign harfbuzz;
hb_buffer_clear_contents        :: (buffer: *void) -> void #foreign harfbuzz;
hb_buffer_add_utf8              :: (buffer: *void, text: *u8, text_len: s32,
                                    item_offset: u32, item_len: s32) -> void #foreign harfbuzz;
hb_buffer_guess_segment_properties :: (buffer: *void) -> void #foreign harfbuzz;
hb_shape                        :: (font: *void, buffer: *void, features: *void,
                                    num_features: u32) -> void #foreign harfbuzz;
hb_buffer_get_glyph_infos       :: (buffer: *void, length: *u32) -> *HbGlyphInfo #foreign harfbuzz;
hb_buffer_get_glyph_positions   :: (buffer: *void, length: *u32) -> *HbGlyphPosition #foreign harfbuzz;

// Fontconfig bindings. These discover fonts on the user's machine so the
// emulator does not depend on any particular font file being installed.
FcFontSet :: struct {
  nfont: s32;
  sfont: s32;
  fonts: **void;
}

FcInit                :: () -> s32 #foreign fontconfig;
FcConfigGetCurrent    :: () -> *void #foreign fontconfig;
FcConfigSubstitute    :: (config: *void, p: *void, kind: s32) -> s32 #foreign fontconfig;
FcDefaultSubstitute   :: (p: *void) -> void #foreign fontconfig;
FcFontMatch           :: (config: *void, p: *void, result: *s32) -> *void #foreign fontconfig;
FcFontSort            :: (config: *void, p: *void, trim: s32, csp: **void, result: *s32) -> *FcFontSet #foreign fontconfig;
FcFontSetDestroy      :: (s: *FcFontSet) -> void #foreign fontconfig;
FcPatternCreate       :: () -> *void #foreign fontconfig;
FcPatternDestroy      :: (p: *void) -> void #foreign fontconfig;
FcPatternAddString    :: (p: *void, object: *u8, s: *u8) -> s32 #foreign fontconfig;
FcPatternAddInteger   :: (p: *void, object: *u8, i: s32) -> s32 #foreign fontconfig;
FcPatternAddBool      :: (p: *void, object: *u8, b: s32) -> s32 #foreign fontconfig;
FcPatternAddCharSet   :: (p: *void, object: *u8, c: *void) -> s32 #foreign fontconfig;
FcPatternGetString    :: (p: *void, object: *u8, n: s32, s: **u8) -> s32 #foreign fontconfig;
FcPatternGetInteger   :: (p: *void, object: *u8, n: s32, i: *s32) -> s32 #foreign fontconfig;
FcPatternGetCharSet   :: (p: *void, object: *u8, n: s32, c: **void) -> s32 #foreign fontconfig;
FcCharSetCreate       :: () -> *void #foreign fontconfig;
FcCharSetDestroy      :: (c: *void) -> void #foreign fontconfig;
FcCharSetAddChar      :: (c: *void, cp: u32) -> s32 #foreign fontconfig;
FcCharSetHasChar      :: (c: *void, cp: u32) -> s32 #foreign fontconfig;

FT_FACE_FLAG_SCALABLE :: 1 << 0;
FT_FACE_FLAG_COLOR    :: 1 << 14;
FT_LOAD_RENDER        :: 1 << 2;
FT_LOAD_COLOR         :: 1 << 20;

FT_PIXEL_MODE_GRAY :: 2;
FT_PIXEL_MODE_BGRA :: 7;

FT_RENDER_MODE_NORMAL   :: 0;
FT_GLYPH_FORMAT_OUTLINE :: 0x6F75746C; // 'outl'
FT_GLYPH_FORMAT_BITMAP  :: 0x6269746D; // 'bitm'
FT_GLYPH_FORMAT_SVG     :: 0x53564720; // 'SVG '

// Offset of FT_GlyphSlotRec.other (the OT-SVG document pointer).
FT_SLOT_OTHER_OFFSET :: 288;

