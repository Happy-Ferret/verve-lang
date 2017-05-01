%{
open Absyn
%}

/* keywords */
%token CASE
%token ENUM
%token FN
%token INTERFACE
%token IMPLEMENTATION
%token MATCH

/* punctuation */
%token ARROW
%token COLON
%token COMMA
%token DOT
%token EQ
%token UNDERSCORE
%token L_ANGLE
%token R_ANGLE
%token L_BRACE
%token R_BRACE
%token L_PAREN
%token R_PAREN
%token NL_L_PAREN
%token EOF

/* tokens with semantic values */
%token <string> LCID
%token <string> UCID
%token <int> INT

%start <Absyn.program> program
%start <Absyn.decl> decl_start

%nonassoc BELOW_PAREN
%left L_PAREN L_ANGLE

%%

/* Helpers */

%inline angles(x): delimited(L_ANGLE, x, R_ANGLE) { $1 }
%inline braces(x): delimited(L_BRACE, x, R_BRACE) { $1 }
%inline parens(x): delimited(L_PAREN, x, R_PAREN) { $1 }

%inline plist(x): parens(separated_list(COMMA, x)) { $1 }
%inline blist(x): braces(separated_list(COMMA, x)) { $1 }

%inline nonempty_alist(x): angles(separated_nonempty_list(COMMA, x)) { $1 }

/* Entry points */
program: decl* EOF {
  { imports = []; exports = []; body = $1 }
}

decl_start: decl EOF { $1 }

/* high-level structures */
decl:
  | enum { $1 }
  | interface { $1 }
  | implementation { $1 }
  | expr { Expr $1 }

expr:
  | function_ { Function $1 }
  | record { $1 }
  | match_expr { $1 }
  | constructor { $1 }
  | constructor_no_args %prec BELOW_PAREN { $1 }
  | atom %prec BELOW_PAREN { $1 }

atom:
  | LCID { Var $1 }
  | literal { Literal $1 }
  | field_access { $1 }
  | second_application { $1 }
  | first_application %prec BELOW_PAREN { $1 }
  | parens(expr) { $1 }
  | NL_L_PAREN expr R_PAREN { $2 }

/* function expressions */
function_: FN LCID generic_parameters plist(parameter) ARROW type_ braces(list(expr)) {
  { fn_name = Some $2; fn_generics = $3; fn_parameters = $4; fn_return_type = $6; fn_body = $7 }
}

generic_parameters: loption(nonempty_alist(generic_parameter)) { $1 }

generic_parameter: UCID loption(COLON quantifiers { $2 }) {
  { name = $1; constraints = $2 }
}

quantifiers:
  | UCID { [$1] }
  | plist(UCID) { $1 }

parameter: LCID COLON type_ {
  { param_name = $1; param_type = $3 }
}

/* types */
type_:
  | UCID generic_arguments { Inst ($1, $2) }
  | arrow_type { $1 }
  | record_type { $1 }

arrow_type: plist(type_) ARROW type_ { Arrow($1, $3) }

record_type: blist(record_type_field) { RecordType $1 }

record_type_field: LCID COLON type_ { ($1, $3) }

/* application */

%inline application(x):
  | x plist(expr) {
    Application { callee = $1; generic_arguments = []; arguments = Some $2; generic_arguments_ty = [] }
  }
  | x generic_arguments_strict {
    Application { callee = $1; generic_arguments = $2; arguments = None; generic_arguments_ty = [] }
  }

second_application: application(first_application) { $1 }
first_application: application(atom) { $1 }

generic_arguments: loption(generic_arguments_strict) { $1 }

generic_arguments_strict: nonempty_alist(type_) { $1 }

/* literals */
literal:
  | int_ { $1 }

int_: INT { Int $1 }

/* enums */
enum: ENUM UCID generic_parameters braces(nonempty_list(enum_item)) {
  Enum { enum_name = $2; enum_generics = $3; enum_items = $4 }
}

enum_item: UCID generic_parameters plist(type_)? {
  { enum_item_name = $1; enum_item_generics = $2; enum_item_parameters = $3; }
}

%inline constructor_no_args: UCID generic_arguments {
  Ctor { ctor_name = $1; ctor_generic_arguments = $2; ctor_arguments = None }
}

%inline constructor: UCID generic_arguments plist(expr) {
  Ctor { ctor_name = $1; ctor_generic_arguments = $2; ctor_arguments = Some $3 }
}

/* interfaces */
interface: INTERFACE UCID angles(generic_parameter) braces(list(prototype)) {
  Interface { intf_name = $2; intf_param = $3; intf_functions = $4; }
}

prototype: FN LCID generic_parameters plist(type_) ARROW type_ {
  { proto_name = $2; proto_generics = $3; proto_params = $4; proto_ret_type = $6 }
}

/* implementations */
implementation: IMPLEMENTATION UCID angles(type_) braces(list(function_)) {
  Implementation { impl_name = $2; impl_arg = $3; impl_functions = $4; impl_arg_type = None }
}

/* Records */

record: blist(record_field) { Record $1 }
record_field: LCID EQ expr { ($1, $3) }

field_access: atom DOT LCID {
  Field_access { record = $1; field = $3; }
}

/* pattern matching */
match_expr: MATCH expr braces(nonempty_list(match_case)) {
  Match { match_value = $2; cases = $3 }
}

match_case: CASE pattern COLON nonempty_list(expr) {
  { pattern = $2; case_value = $4 }
}

pattern:
  | UNDERSCORE { Pany }
  | LCID { Pvar $1 }
  | UCID option(plist(pattern)) { Pctor ($1, $2) }
