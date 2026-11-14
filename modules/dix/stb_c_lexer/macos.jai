//
// This file was auto-generated using the following command:
//
// jai generate.jai
//



stb_lexer :: struct {
    // lexer variables
    input_stream:       *u8;
    eof:                *u8;
    parse_point:        *u8;
    string_storage:     *u8;
    string_storage_len: s32;

    // lexer parse location for error messages
    where_firstchar:    *u8;
    where_lastchar:     *u8;

    // lexer token variables
    token:              s64;
    real_number:        float64;
    int_number:         s64;
    _string:            *u8;
    string_len:         s32;
}

stb_lex_location :: struct {
    line_number: s32;
    line_offset: s32;
}

stb_c_lexer_init :: (lexer: *stb_lexer, input_stream: *u8, input_stream_end: *u8, string_store: *u8, store_length: s32) -> void #foreign stb_c_lexer;

// this function initialize the 'lexer' structure
//   Input:
//   - input_stream points to the file to parse, loaded into memory
//   - input_stream_end points to the end of the file, or NULL if you use 0-for-EOF
//   - string_store is storage the lexer can use for storing parsed strings and identifiers
//   - store_length is the length of that storage
stb_c_lexer_get_token :: (lexer: *stb_lexer) -> s32 #foreign stb_c_lexer;

// this function returns non-zero if a token is parsed, or 0 if at EOF
//   Output:
//   - lexer->token is the token ID, which is unicode code point for a single-char token, < 0 for a multichar or eof or error
//   - lexer->real_number is a double constant value for CLEX_floatlit, or CLEX_intlit if STB_C_LEX_INTEGERS_AS_DOUBLES
//   - lexer->int_number is an integer constant for CLEX_intlit if !STB_C_LEX_INTEGERS_AS_DOUBLES, or character for CLEX_charlit
//   - lexer->string is a 0-terminated string for CLEX_dqstring or CLEX_sqstring or CLEX_identifier
//   - lexer->string_len is the byte length of lexer->string
stb_c_lexer_get_location :: (lexer: *stb_lexer, where: *u8, loc: *stb_lex_location) -> void #foreign stb_c_lexer;

CLEX :: enum u32 {
    eof                :: 256;
    parse_error        :: 257;
    intlit             :: 258;
    floatlit           :: 259;
    id                 :: 260;
    dqstring           :: 261;
    sqstring           :: 262;
    charlit            :: 263;
    eq                 :: 264;
    noteq              :: 265;
    lesseq             :: 266;
    greatereq          :: 267;
    andand             :: 268;
    oror               :: 269;
    shl                :: 270;
    shr                :: 271;
    plusplus           :: 272;
    minusminus         :: 273;
    pluseq             :: 274;
    minuseq            :: 275;
    muleq              :: 276;
    diveq              :: 277;
    modeq              :: 278;
    andeq              :: 279;
    oreq               :: 280;
    xoreq              :: 281;
    arrow              :: 282;
    eqarrow            :: 283;
    shleq              :: 284;
    shreq              :: 285;

    first_unused_token :: 286;

    CLEX_eof                :: eof;
    CLEX_parse_error        :: parse_error;
    CLEX_intlit             :: intlit;
    CLEX_floatlit           :: floatlit;
    CLEX_id                 :: id;
    CLEX_dqstring           :: dqstring;
    CLEX_sqstring           :: sqstring;
    CLEX_charlit            :: charlit;
    CLEX_eq                 :: eq;
    CLEX_noteq              :: noteq;
    CLEX_lesseq             :: lesseq;
    CLEX_greatereq          :: greatereq;
    CLEX_andand             :: andand;
    CLEX_oror               :: oror;
    CLEX_shl                :: shl;
    CLEX_shr                :: shr;
    CLEX_plusplus           :: plusplus;
    CLEX_minusminus         :: minusminus;
    CLEX_pluseq             :: pluseq;
    CLEX_minuseq            :: minuseq;
    CLEX_muleq              :: muleq;
    CLEX_diveq              :: diveq;
    CLEX_modeq              :: modeq;
    CLEX_andeq              :: andeq;
    CLEX_oreq               :: oreq;
    CLEX_xoreq              :: xoreq;
    CLEX_arrow              :: arrow;
    CLEX_eqarrow            :: eqarrow;
    CLEX_shleq              :: shleq;
    CLEX_shreq              :: shreq;

    CLEX_first_unused_token :: first_unused_token;
}

#scope_file

#import "Basic"; // For assert

stb_c_lexer :: #library "./libs/macos/libstb_c_lexer";

#run {
    {
        info := type_info(stb_lexer);
        for info.members {
            if it.name == {
                case "input_stream";
                    assert(it.offset_in_bytes == 0, "stb_lexer.input_stream has unexpected offset % instead of 0", it.offset_in_bytes);
                    assert(it.type.runtime_size == 8, "stb_lexer.input_stream has unexpected size % instead of 8", it.type.runtime_size);
                case "eof";
                    assert(it.offset_in_bytes == 8, "stb_lexer.eof has unexpected offset % instead of 8", it.offset_in_bytes);
                    assert(it.type.runtime_size == 8, "stb_lexer.eof has unexpected size % instead of 8", it.type.runtime_size);
                case "parse_point";
                    assert(it.offset_in_bytes == 16, "stb_lexer.parse_point has unexpected offset % instead of 16", it.offset_in_bytes);
                    assert(it.type.runtime_size == 8, "stb_lexer.parse_point has unexpected size % instead of 8", it.type.runtime_size);
                case "string_storage";
                    assert(it.offset_in_bytes == 24, "stb_lexer.string_storage has unexpected offset % instead of 24", it.offset_in_bytes);
                    assert(it.type.runtime_size == 8, "stb_lexer.string_storage has unexpected size % instead of 8", it.type.runtime_size);
                case "string_storage_len";
                    assert(it.offset_in_bytes == 32, "stb_lexer.string_storage_len has unexpected offset % instead of 32", it.offset_in_bytes);
                    assert(it.type.runtime_size == 4, "stb_lexer.string_storage_len has unexpected size % instead of 4", it.type.runtime_size);
                case "where_firstchar";
                    assert(it.offset_in_bytes == 40, "stb_lexer.where_firstchar has unexpected offset % instead of 40", it.offset_in_bytes);
                    assert(it.type.runtime_size == 8, "stb_lexer.where_firstchar has unexpected size % instead of 8", it.type.runtime_size);
                case "where_lastchar";
                    assert(it.offset_in_bytes == 48, "stb_lexer.where_lastchar has unexpected offset % instead of 48", it.offset_in_bytes);
                    assert(it.type.runtime_size == 8, "stb_lexer.where_lastchar has unexpected size % instead of 8", it.type.runtime_size);
                case "token";
                    assert(it.offset_in_bytes == 56, "stb_lexer.token has unexpected offset % instead of 56", it.offset_in_bytes);
                    assert(it.type.runtime_size == 8, "stb_lexer.token has unexpected size % instead of 8", it.type.runtime_size);
                case "real_number";
                    assert(it.offset_in_bytes == 64, "stb_lexer.real_number has unexpected offset % instead of 64", it.offset_in_bytes);
                    assert(it.type.runtime_size == 8, "stb_lexer.real_number has unexpected size % instead of 8", it.type.runtime_size);
                case "int_number";
                    assert(it.offset_in_bytes == 72, "stb_lexer.int_number has unexpected offset % instead of 72", it.offset_in_bytes);
                    assert(it.type.runtime_size == 8, "stb_lexer.int_number has unexpected size % instead of 8", it.type.runtime_size);
                case "_string";
                    assert(it.offset_in_bytes == 80, "stb_lexer._string has unexpected offset % instead of 80", it.offset_in_bytes);
                    assert(it.type.runtime_size == 8, "stb_lexer._string has unexpected size % instead of 8", it.type.runtime_size);
                case "string_len";
                    assert(it.offset_in_bytes == 88, "stb_lexer.string_len has unexpected offset % instead of 88", it.offset_in_bytes);
                    assert(it.type.runtime_size == 4, "stb_lexer.string_len has unexpected size % instead of 4", it.type.runtime_size);
            }
        }
        assert(size_of(stb_lexer) == 96, "stb_lexer has size % instead of 96", size_of(stb_lexer));
    }

    {
        info := type_info(stb_lex_location);
        for info.members {
            if it.name == {
                case "line_number";
                    assert(it.offset_in_bytes == 0, "stb_lex_location.line_number has unexpected offset % instead of 0", it.offset_in_bytes);
                    assert(it.type.runtime_size == 4, "stb_lex_location.line_number has unexpected size % instead of 4", it.type.runtime_size);
                case "line_offset";
                    assert(it.offset_in_bytes == 4, "stb_lex_location.line_offset has unexpected offset % instead of 4", it.offset_in_bytes);
                    assert(it.type.runtime_size == 4, "stb_lex_location.line_offset has unexpected size % instead of 4", it.type.runtime_size);
            }
        }
        assert(size_of(stb_lex_location) == 8, "stb_lex_location has size % instead of 8", size_of(stb_lex_location));
    }
}

