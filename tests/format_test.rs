//! Format tests — explicit input→output tests for Julia formatting.
//!
//! Run all:     cargo test --test format_test
//! Run suite:   cargo test --test format_test functions::
//! Run one:     cargo test --test format_test functions::basic

mod common;

macro_rules! format_test {
    ($name:ident, $input:expr, $expected:expr) => {
        #[test]
        fn $name() {
            let actual = common::format_julia($input);
            pretty_assertions::assert_eq!(actual.trim_end(), $expected.trim_end());
        }
    };
}

macro_rules! idempotent_test {
    ($name:ident, $input:expr) => {
        #[test]
        fn $name() {
            common::assert_idempotent($input);
        }
    };
}

mod functions {
    use super::common;
    format_test!(basic, "function foo(x,y)\nx+y\nend\n", "function foo(x, y)\n    x + y\nend");
    format_test!(already_formatted, "function foo(x, y)\n    x + y\nend\n", "function foo(x, y)\n    x + y\nend");
    format_test!(short_def, "f(x) = x+1\n", "f(x) = x + 1");
    format_test!(short_def_multi_arg, "g(x,y) = x*y\n", "g(x, y) = x * y");
    format_test!(nested_if, "function f(x)\nif x>0\nreturn x\nend\nend\n", "function f(x)\n    if x > 0\n        return x\n    end\nend");
    format_test!(multiple, "function f()\n1\nend\nfunction g()\n2\nend\n", "function f()\n    1\nend\nfunction g()\n    2\nend");
    format_test!(return_value, "function f()\nreturn 42\nend\n", "function f()\n    return 42\nend");
    format_test!(arrow, "f = x->x+1\n", "f = x -> x + 1");
    format_test!(where_clause, "function f(x::T) where T\nx\nend\n", "function f(x::T) where T\n    x\nend");
    format_test!(where_subtype, "function f(x::T) where T<:Number\nx\nend\n", "function f(x::T) where T <: Number\n    x\nend");
    format_test!(keyword_args, "function foo(x,y=1;z=2)\nx\nend\n", "function foo(x, y = 1; z = 2)\n    x\nend");
    format_test!(named_arg_call, "f(1,key=value)\n", "f(1, key = value)");
}

mod control_flow {
    use super::common;
    format_test!(if_simple, "if x>0\nprintln(x)\nend\n", "if x > 0\n    println(x)\nend");
    format_test!(if_else, "if x>0\na\nelse\nb\nend\n", "if x > 0\n    a\nelse\n    b\nend");
    format_test!(if_elseif_else, "if x>0\na\nelseif x<0\nb\nelse\nc\nend\n", "if x > 0\n    a\nelseif x < 0\n    b\nelse\n    c\nend");
    format_test!(for_loop, "for i in 1:10\nprintln(i)\nend\n", "for i in 1:10\n    println(i)\nend");
    format_test!(while_loop, "while x>0\nx=x-1\nend\n", "while x > 0\n    x = x - 1\nend");
    format_test!(try_catch, "try\nf()\ncatch e\nprintln(e)\nend\n", "try\n    f()\ncatch e\n    println(e)\nend");
    format_test!(try_catch_finally, "try\nf()\ncatch e\nprintln(e)\nfinally\ncleanup()\nend\n", "try\n    f()\ncatch e\n    println(e)\nfinally\n    cleanup()\nend");
    // Known limitation: comma placement in multi-binding for.
    format_test!(for_multi_binding, "for i in 1:3, j in 1:3\nprintln(i,j)\nend\n", "for i in 1:3, j in 1:3\n    println(i, j)\nend");
    format_test!(multiple_returns, "return a\nreturn b\n", "return a\nreturn b");
}

mod types {
    use super::common;
    format_test!(struct_basic, "struct Point\nx::Float64\ny::Float64\nend\n", "struct Point\n    x::Float64\n    y::Float64\nend");
    format_test!(mutable_struct, "mutable struct Foo\nx::Int\ny::Int\nend\n", "mutable struct Foo\n    x::Int\n    y::Int\nend");
    format_test!(abstract_type, "abstract type Shape end\n", "abstract type Shape end");
    format_test!(abstract_subtype, "abstract type Circle<:Shape end\n", "abstract type Circle <: Shape end");
    format_test!(primitive_type, "primitive type UInt8 8 end\n", "primitive type UInt8 8 end");
}

mod operators {
    use super::common;
    format_test!(assignment, "x=1\n", "x = 1");
    format_test!(binary, "a+b*c\n", "a + b * c");
    format_test!(ternary, "x>0 ? x : -x\n", "x > 0 ? x : -x");
    format_test!(prefix_op_tuple, "+ (a, b)\n", "+ (a, b)");
    format_test!(prefix_op_no_space, "+(a, b)\n", "+(a, b)");
    format_test!(block_type_annotation, "begin x end::T\n", "begin\n    x\nend::T");
    format_test!(broadcast_call, "f.(x)\n", "f.(x)");
    format_test!(broadcast_op, "x .+ y\n", "x .+ y");
}

mod blocks {
    use super::common;
    format_test!(begin, "begin\na=1\nb=2\nend\n", "begin\n    a = 1\n    b = 2\nend");
    format_test!(module_basic, "module MyMod\nend\n", "module MyMod\nend");
    format_test!(let_simple, "let x=1\nx+y\nend\n", "let x = 1\n    x + y\nend");
    format_test!(let_empty, "let\nend\n", "let\nend");
    format_test!(blank_lines_preserved, "function f()\n1\nend\n\nfunction g()\n2\nend\n", "function f()\n    1\nend\n\nfunction g()\n    2\nend");
    format_test!(do_block, "map([1,2,3]) do x\nx+1\nend\n", "map([1, 2, 3]) do x\n    x + 1\nend");
    format_test!(do_block_no_args, "open(\"f\") do io\nread(io)\nend\n", "open(\"f\") do io\n    read(io)\nend");
}

mod imports {
    use super::common;
    format_test!(using, "using LinearAlgebra\nimport Base: show,print\n", "using LinearAlgebra\nimport Base: show, print");
    format_test!(import_as, "import LinearAlgebra as la\n", "import LinearAlgebra as la");
    format_test!(relative_single, "import .A\n", "import .A");
    format_test!(relative_double, "import ..A\n", "import ..A");
    format_test!(relative_triple, "import ...A\n", "import ...A");
    format_test!(dotted_path, "import Foo.Bar\n", "import Foo.Bar");
}

mod macros {
    use super::common;
    format_test!(call_space, "@assert x==y\n", "@assert x == y");
    format_test!(space_separated, "@foo a b\n", "@foo a b");
    format_test!(paren_no_space, "@x(a, b)\n", "@x(a, b)");
    // TODO: qualified macro spacing (A.@foo a b) needs work in v0.25.0
}

mod collections {
    use super::common;
    format_test!(comprehension_basic, "[x^2 for x in 1:10]\n", "[x ^ 2 for x in 1:10]");
    format_test!(comprehension_filtered, "[x for x in xs if x>0]\n", "[x for x in xs if x > 0]");
    format_test!(matrix_vcat, "[x; y; z]\n", "[x; y; z]");
    format_test!(matrix_2x2, "[x y; z w]\n", "[x y; z w]");
    format_test!(matrix_typed_vcat, "T[x; y]\n", "T[x; y]");
    format_test!(matrix_hcat, "[a b c]\n", "[a b c]");
    format_test!(matrix_newline_sep, "[x\ny]\n", "[x\ny]");
    format_test!(string_interpolation, "\"hello $name and $(x+1)\"\n", "\"hello $name and $(x+1)\"");
}

mod idempotence {
    use super::common;
    idempotent_test!(function, "function foo(x,y)\nx+y\nend\n");
    idempotent_test!(if_else, "if x>0\na\nelse\nb\nend\n");
    idempotent_test!(for_loop, "for i in 1:10\nprintln(i)\nend\n");
    idempotent_test!(struct_def, "struct Point\nx::Float64\ny::Float64\nend\n");
    idempotent_test!(where_clause, "function f(x::T) where T\nx\nend\n");
    idempotent_test!(do_block, "map([1,2,3]) do x\nx+1\nend\n");
    idempotent_test!(comprehension, "[x^2 for x in 1:10]\n");
    idempotent_test!(macro_call, "@assert x==y\n");
    idempotent_test!(abstract_type, "abstract type Shape end\n");
    idempotent_test!(primitive_type, "primitive type UInt8 8 end\n");
}
