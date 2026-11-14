Dix :: Any;  
Object :: Table(string, Any);

Expr_Kind :: enum {
  VARIABLE;
}

Expr :: union kind: Expr_Kind {
  .VARIABLE,, variable: struct { path: []string; };
}

Outcome :: enum {
  FOUND;
  UNKNOWN;
  STACK_OVERFLOW;
}

MAX_STACK_SIZE :: 100;

get_dix_value :: (root: Dix, path: ..string, level: int = 1) -> (value: Dix, outcome: Outcome) {
  if level > MAX_STACK_SIZE return Any.{}, .STACK_OVERFLOW;
  
  cursor := root; 
  for key: path {
    if cursor.type != cast(*Type_Info)Object return Any.{}, .UNKNOWN;
    object := cast(*Object)cursor.value_pointer;
    ok, next_cursor := table_find(object, key);
    if !ok return Any.{}, .UNKNOWN;
    cursor = next_cursor;
  }

  if cursor.type != cast(*Type_Info)Expr return cursor, .FOUND;

  expr : *Expr = cursor.value_pointer;
  if #complete expr.kind == {
    case .VARIABLE; 
      value, outcome := get_dix_value(root, ..expr.variable.path, level + 1);
      return value, outcome;
  }
  return cursor, .FOUND;
}

get_dix_value :: (root: Dix, $T: Type, path: ..string) -> *T {
  cursor, outcome := get_dix_value(root, ..path);
  if outcome != .FOUND return null;
  if cursor.type != cast(*Type_Info)T return null;
  return cursor.value_pointer;
}

load_dix_from_file :: (file_path: string) -> (dix: Dix, ok: bool) {
  content, ok := read_entire_file(file_path); 
  if !ok return Any.{}, false;
  
  l: stb_lexer;

  string_store: [1024]u8;

  stb_c_lexer_init(*l, content.data, content.data + content.count, string_store.data, string_store.count);

  value := New(Object);
  if !parse_object_body(file_path, *l, value) return Any.{}, false;
  return Any.{cast(*Type_Info)Object, value}, true;

}

dump_value :: (root: Dix) {
  dump_value_impl :: (root: Dix, current: Dix, level: int) { 
    if current.type.type == {
      case .FLOAT; #through;
      case .INTEGER; #through;
      case .STRING; print("\"%\"", current);
      case .BOOL; print("%", current);
      case .STRUCT;
        if current.type == cast(*Type_Info)Object {
          object : *Object = current.value_pointer; 
          print("{\n");
          for object {
            for 1..level+1 print("  "); print("% => ", it_index); 
            dump_value_impl(root, it, level + 1);
            print(",\n");
          }
          for 1..level print("  "); print("}");
        } else if current.type == cast(*Type_Info)Expr {
          expr : *Expr = current.value_pointer;
          if #complete expr.kind == {
            case .VARIABLE; 
              value, outcome := get_dix_value(root, ..expr.variable.path);
              if #complete outcome == {
                case .FOUND; dump_value_impl(root, value, level + 1); 
                case .UNKNOWN; print("[MISSING]");
                case .STACK_OVERFLOW; print("[STACK OVERFLOW]");
              }
          }
        } else {
          assert(false, "unreachable");
        }
      case; assert(false, "unreachable");
    }
  }

  dump_value_impl(root, root, 0);
}


#scope_file

expect_tokens :: (file_path: string, l: *stb_lexer, expected_tokens: s64) -> (ok: bool) {
  stb_c_lexer_get_token(l);
  if l.token != expected_tokens {
    report_error(file_path, l, "ERROR: Unexpected token. Expected % but got %", expected_tokens, l.token);
    return false;
  }

  return true;
}

report_error :: (file_path: string, l: *stb_lexer, format_string: string, args: .. Any) {
  loc: stb_lex_location;
  stb_c_lexer_get_location(l, l.where_firstchar, *loc);
  print("%:%:%\n", file_path, loc.line_number, loc.line_offset);
  print(format_string, ..args);
  print("\n");
}

parse_value :: (file_path: string, l: *stb_lexer) -> value: Dix, ok: bool {
  stb_c_lexer_get_token(l);
  if l.token == {
    case #char "{";
      value := New(Object);
      if !parse_object_body(file_path, l, value) return Any.{}, false;
      // We expect parse_object_body to consume `}` for us
      return Any.{cast(*Type_Info)Object, value}, true;

    case xx CLEX.floatlit;
      value := New(float);
      value.* = xx l.real_number;
      return Any.{cast(*Type_Info)float, value}, true;

    case xx CLEX.intlit;
      value := New(int);
      value.* = xx l.int_number;
      return Any.{cast(*Type_Info)int, value}, true;

    case xx CLEX.id;
      id := copy_string(to_string(l._string));
      if id == {
        case "true";
          value := New(bool);
          value.* = true;
          return Any.{cast(*Type_Info)bool, value}, true;
        case "false";
          value := New(bool);
          value.* = false;
          return Any.{cast(*Type_Info)bool, value}, true;
        case;
          path: [..]string;
          array_add(*path, id);
          // config.hero_data.name
          saved_l := l.*;
          stb_c_lexer_get_token(l);
          while l.token == #char "." {
            if !expect_tokens(file_path, l, xx CLEX.id) return Any.{}, false;
            array_add(*path, copy_string(to_string(l._string)));
            saved_l = l.*;
            stb_c_lexer_get_token(l);
          }
          l.* = saved_l;
         
          value := New(Expr);
          value.kind = .VARIABLE;
          value.variable.path = path; 
          
          return Any.{cast(*Type_Info)Expr, value}, true;
      }

    case xx CLEX.dqstring;
      value := New(string);
      value.* = copy_string(to_string(l._string));
      return Any.{cast(*Type_Info)string, value}, true;

    case;
      report_error(file_path, l, "ERROR: Unexpected token %\n", l.token);
      return Any.{}, false;
   }

  assert(false, "unreachable");
  return Any.{}, false;
}

parse_object_body :: (file_path: string, l: *stb_lexer, object: *Object) -> (ok: bool) {
  while true { 
    saved_l := l.*;
    stb_c_lexer_get_token(l);;
    if l.token == #char "}" || l.token == xx CLEX.eof return true;
    l.* = saved_l;

    if !expect_tokens(file_path, l, xx CLEX.id) return false;
    key := copy_string(to_string(l._string));
    if table_contains(object, key) {
      report_error(file_path, l, "ERROR: Redefinition of field %", key); 
      return false;
    }
    if !expect_tokens(file_path, l, #char "=") return false;
    value, ok := parse_value(file_path, l);
    if !ok return false;
    if !expect_tokens(file_path, l, #char ";") return false;
    table_add(object, key, value);
  }

  assert(false, "unreachable");
  return false;
}

#import,file "stb_c_lexer/module.jai";
#import "Basic";
#import "File";
#import "Hash_Table";
