use topiary_core::{formatter, Language, Operation, TopiaryQuery};
use topiary_tree_sitter_facade::Language as Grammar;

const QUERY: &str = include_str!("../julia.scm");

fn make_language() -> Language {
    let grammar: Grammar = tree_sitter_julia::LANGUAGE.into();
    let query = TopiaryQuery::new(&grammar, QUERY).expect("Invalid query file");
    Language {
        name: "julia".into(),
        query,
        grammar,
        indent: Some("    ".into()),
    }
}

fn format_julia(input: &str) -> String {
    let language = make_language();
    let mut output = Vec::new();
    formatter(
        &mut input.as_bytes(),
        &mut output,
        &language,
        Operation::Format {
            skip_idempotence: true,
            tolerate_parsing_errors: false,
        },
    )
    .expect("Formatting failed");
    String::from_utf8(output).expect("Non-UTF8 output")
}

/// Format, then format again — output must be identical.
fn assert_idempotent(input: &str) {
    let first = format_julia(input);
    let second = format_julia(&first);
    pretty_assertions::assert_eq!(first, second, "Not idempotent");
}

macro_rules! format_test {
    ($name:ident, $input:expr, $expected:expr) => {
        #[test]
        fn $name() {
            let actual = format_julia($input);
            pretty_assertions::assert_eq!(actual.trim_end(), $expected.trim_end());
        }
    };
}

macro_rules! idempotent_test {
    ($name:ident, $input:expr) => {
        #[test]
        fn $name() {
            assert_idempotent($input);
        }
    };
}

// ── Functions ────────────────────────────────────────────────

format_test!(
    function_basic,
    "function foo(x,y)\nx+y\nend\n",
    "function foo(x, y)\n    x + y\nend"
);

format_test!(
    function_already_formatted,
    "function foo(x, y)\n    x + y\nend\n",
    "function foo(x, y)\n    x + y\nend"
);

// ── If / elseif / else ──────────────────────────────────────

format_test!(
    if_simple,
    "if x>0\nprintln(x)\nend\n",
    "if x > 0\n    println(x)\nend"
);

format_test!(
    if_else,
    "if x>0\na\nelse\nb\nend\n",
    "if x > 0\n    a\nelse\n    b\nend"
);

format_test!(
    if_elseif_else,
    "if x>0\na\nelseif x<0\nb\nelse\nc\nend\n",
    "if x > 0\n    a\nelseif x < 0\n    b\nelse\n    c\nend"
);

// ── For / while ─────────────────────────────────────────────

format_test!(
    for_loop,
    "for i in 1:10\nprintln(i)\nend\n",
    "for i in 1:10\n    println(i)\nend"
);

format_test!(
    while_loop,
    "while x>0\nx=x-1\nend\n",
    "while x > 0\n    x = x - 1\nend"
);

// ── Struct ──────────────────────────────────────────────────

format_test!(
    struct_basic,
    "struct Point\nx::Float64\ny::Float64\nend\n",
    "struct Point\n    x::Float64\n    y::Float64\nend"
);

// ── Module ──────────────────────────────────────────────────

format_test!(
    module_basic,
    "module MyMod\nend\n",
    "module MyMod\nend"
);

// ── Try / catch / finally ───────────────────────────────────

format_test!(
    try_catch,
    "try\nf()\ncatch e\nprintln(e)\nend\n",
    "try\n    f()\ncatch e\n    println(e)\nend"
);

// ── Operators ───────────────────────────────────────────────

format_test!(
    assignment_spacing,
    "x=1\n",
    "x = 1"
);

format_test!(
    binary_op_spacing,
    "a+b*c\n",
    "a + b * c"
);

format_test!(
    ternary_spacing,
    "x>0 ? x : -x\n",
    "x > 0 ? x : -x"
);

// ── More constructs ─────────────────────────────────────────

format_test!(
    begin_block,
    "begin\na=1\nb=2\nend\n",
    "begin\n    a = 1\n    b = 2\nend"
);

format_test!(
    nested_if_in_function,
    "function f(x)\nif x>0\nreturn x\nend\nend\n",
    "function f(x)\n    if x > 0\n        return x\n    end\nend"
);

format_test!(
    arrow_function,
    "f = x->x+1\n",
    "f = x -> x + 1"
);

format_test!(
    import_using,
    "using LinearAlgebra\nimport Base: show,print\n",
    "using LinearAlgebra\nimport Base: show, print"
);

format_test!(
    multiple_functions,
    "function f()\n1\nend\nfunction g()\n2\nend\n",
    "function f()\n    1\nend\nfunction g()\n    2\nend"
);

format_test!(
    try_catch_finally,
    "try\nf()\ncatch e\nprintln(e)\nfinally\ncleanup()\nend\n",
    "try\n    f()\ncatch e\n    println(e)\nfinally\n    cleanup()\nend"
);

format_test!(
    mutable_struct,
    "mutable struct Foo\nx::Int\ny::Int\nend\n",
    "mutable struct Foo\n    x::Int\n    y::Int\nend"
);

format_test!(
    let_block_simple,
    "let x=1\nx+y\nend\n",
    "let x = 1\n    x + y\nend"
);

// ── Where clause ────────────────────────────────────────────

format_test!(
    where_clause,
    "function f(x::T) where T\nx\nend\n",
    "function f(x::T) where T\n    x\nend"
);

format_test!(
    where_clause_subtype,
    "function f(x::T) where T<:Number\nx\nend\n",
    "function f(x::T) where T <: Number\n    x\nend"
);

// ── Do blocks ───────────────────────────────────────────────

format_test!(
    do_block,
    "map([1,2,3]) do x\nx+1\nend\n",
    "map([1, 2, 3]) do x\n    x + 1\nend"
);

format_test!(
    do_block_no_args,
    "open(\"f\") do io\nread(io)\nend\n",
    "open(\"f\") do io\n    read(io)\nend"
);

// ── Keyword arguments ───────────────────────────────────────

format_test!(
    keyword_args_semicolon,
    "function foo(x,y=1;z=2)\nx\nend\n",
    "function foo(x, y = 1; z = 2)\n    x\nend"
);

format_test!(
    named_arg_call,
    "f(1,key=value)\n",
    "f(1, key = value)"
);

// ── Comprehensions ──────────────────────────────────────────

format_test!(
    comprehension_basic,
    "[x^2 for x in 1:10]\n",
    "[x ^ 2 for x in 1:10]"
);

format_test!(
    comprehension_filtered,
    "[x for x in xs if x>0]\n",
    "[x for x in xs if x > 0]"
);

// ── Abstract / primitive types ──────────────────────────────

format_test!(
    abstract_type,
    "abstract type Shape end\n",
    "abstract type Shape end"
);

format_test!(
    abstract_subtype,
    "abstract type Circle<:Shape end\n",
    "abstract type Circle <: Shape end"
);

format_test!(
    primitive_type,
    "primitive type UInt8 8 end\n",
    "primitive type UInt8 8 end"
);

// ── Macros ──────────────────────────────────────────────────

format_test!(
    macro_call_space,
    "@assert x==y\n",
    "@assert x == y"
);

// ── Short function definitions ──────────────────────────────

format_test!(
    short_function_def,
    "f(x) = x+1\n",
    "f(x) = x + 1"
);

format_test!(
    short_function_multi_arg,
    "g(x,y) = x*y\n",
    "g(x, y) = x * y"
);

// ── Blank lines between definitions ─────────────────────────

format_test!(
    blank_lines_preserved,
    "function f()\n1\nend\n\nfunction g()\n2\nend\n",
    "function f()\n    1\nend\n\nfunction g()\n    2\nend"
);

// ── Multi-binding for ───────────────────────────────────────

// Multi-binding for: each binding gets its own line.
// Known limitation: comma lands on the next line with the next binding.
format_test!(
    for_multi_binding,
    "for i in 1:3, j in 1:3\nprintln(i,j)\nend\n",
    "for i in 1:3\n    ,j in 1:3\n    println(i, j)\nend"
);

// ── Empty let ───────────────────────────────────────────────

format_test!(
    let_empty,
    "let\nend\n",
    "let\nend"
);

// ── Import as ───────────────────────────────────────────────

format_test!(
    import_as,
    "import LinearAlgebra as la\n",
    "import LinearAlgebra as la"
);

// ── Broadcast ───────────────────────────────────────────────

format_test!(
    broadcast_call,
    "f.(x)\n",
    "f.(x)"
);

format_test!(
    broadcast_op,
    "x .+ y\n",
    "x .+ y"
);

// ── String interpolation preserved ──────────────────────────

format_test!(
    string_interpolation,
    "\"hello $name and $(x+1)\"\n",
    "\"hello $name and $(x+1)\""
);

// ── Return statements ───────────────────────────────────────

format_test!(
    return_with_value,
    "function f()\nreturn 42\nend\n",
    "function f()\n    return 42\nend"
);

format_test!(
    multiple_returns,
    "return a\nreturn b\n",
    "return a\nreturn b"
);

// ── Relative imports ────────────────────────────────────────

format_test!(import_relative_single, "import .A\n", "import .A");
format_test!(import_relative_double, "import ..A\n", "import ..A");
format_test!(import_relative_triple, "import ...A\n", "import ...A");
format_test!(import_dotted_path, "import Foo.Bar\n", "import Foo.Bar");

format_test!(macro_space_separated, "@foo a b\n", "@foo a b");
format_test!(macro_paren_no_space, "@x(a, b)\n", "@x(a, b)");
format_test!(macro_qualified_space, "A.@foo a b\n", "A.@foo a b");

// ── Idempotence ─────────────────────────────────────────────

idempotent_test!(
    idempotent_where,
    "function f(x::T) where T\nx\nend\n"
);

idempotent_test!(
    idempotent_do_block,
    "map([1,2,3]) do x\nx+1\nend\n"
);

idempotent_test!(
    idempotent_comprehension,
    "[x^2 for x in 1:10]\n"
);

idempotent_test!(
    idempotent_macro,
    "@assert x==y\n"
);

idempotent_test!(
    idempotent_abstract,
    "abstract type Shape end\n"
);

idempotent_test!(
    idempotent_primitive,
    "primitive type UInt8 8 end\n"
);

idempotent_test!(
    idempotent_function,
    "function foo(x,y)\nx+y\nend\n"
);

idempotent_test!(
    idempotent_if_else,
    "if x>0\na\nelse\nb\nend\n"
);

idempotent_test!(
    idempotent_for,
    "for i in 1:10\nprintln(i)\nend\n"
);

idempotent_test!(
    idempotent_struct,
    "struct Point\nx::Float64\ny::Float64\nend\n"
);
