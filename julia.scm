;; topiary-julia formatting queries
;; =============================================================
;; 1. Leaf nodes — preserve content as-is
;; =============================================================

[
  (string_literal)
  (prefixed_string_literal)
  (command_literal)
  (prefixed_command_literal)
  (character_literal)
  (line_comment)
  (block_comment)
] @leaf

;; =============================================================
;; 2. Keyword spacing — space after keywords
;; =============================================================

[
  "function"
  "macro"
  "struct"
  "mutable"
  "type"
  "module"
  "baremodule"
  "abstract"
  "primitive"
  "return"
  "if"
  "elseif"
  "else"
  "for"
  "while"
  "try"
  "catch"
  "finally"
  "begin"
  "let"
  "quote"
  "using"
  "import"
  "export"
  "const"
  "local"
  "global"
  "outer"
  "as"
  "where"
] @append_space

;; =============================================================
;; 3. Block indentation — keyword...end constructs
;;    Pattern: indent after opening line, de-indent before "end"
;; =============================================================

;; --- function / macro ---

(function_definition
  (signature) @append_hardline @append_indent_start
  "end" @prepend_hardline @prepend_indent_end @append_hardline
)

(macro_definition
  (signature) @append_hardline @append_indent_start
  "end" @prepend_hardline @prepend_indent_end @append_hardline
)

;; --- struct ---

(struct_definition
  (type_head) @append_hardline @append_indent_start
  "end" @prepend_hardline @prepend_indent_end @append_hardline
)

;; --- module ---

(module_definition
  name: (_) @append_hardline @append_indent_start
  "end" @prepend_hardline @prepend_indent_end @append_hardline
)

;; --- abstract / primitive type ---
;; These are typically single-line: `abstract type T end`, `primitive type T 64 end`
;; No block body, so no indentation — just ensure spaces.

(abstract_definition
  (type_head) @append_space
  "end" @append_hardline
)

(primitive_definition
  (type_head) @append_space
  (integer_literal) @append_space
  "end" @append_hardline
)

;; --- if ---

(if_statement
  condition: (_) @append_hardline @append_indent_start
  "end" @prepend_hardline @prepend_indent_end @append_hardline
)

;; --- for ---
;; Indent starts from the "for" keyword context. The last for_binding
;; gets the hardline+indent from the blanket (_) @append_hardline rule,
;; combined with this single indent_start on "for".

(for_statement
  "for" @append_indent_start
  "end" @prepend_hardline @prepend_indent_end @append_hardline
)

;; --- while ---

(while_statement
  condition: (_) @append_hardline @append_indent_start
  "end" @prepend_hardline @prepend_indent_end @append_hardline
)

;; --- try ---

(try_statement
  "try" @append_hardline @append_indent_start
  "end" @prepend_hardline @prepend_indent_end @append_hardline
)

;; --- begin / let / quote ---

(compound_statement
  "begin" @append_hardline @append_indent_start
  "end" @prepend_hardline @prepend_indent_end @append_hardline
)

;; let with bindings: bindings stay on same line, body indented below.
;; indent_start and indent_end are paired here.
(let_statement
  (let_binding) @append_hardline @append_indent_start
  "end" @prepend_hardline @prepend_indent_end @append_hardline
)

;; "end" in let_statement: always put it on its own line.
;; For empty let: "let" keyword's @append_space + end's @prepend_hardline
;; gives "let\nend". For let with bindings, the paired rule above handles it.
(let_statement
  "end" @prepend_hardline @append_hardline
)

(quote_statement
  "quote" @append_hardline @append_indent_start
  "end" @prepend_hardline @prepend_indent_end @append_hardline
)

;; --- do clause ---
;; "do" gets space before it (prepend) and space after (append, for args).
;; Indent starts after "do": the blanket (_) @append_hardline rule
;; ensures newlines after the argument_list (or body exprs).
;; "end" de-indents and sits on its own line.

(do_clause
  "do" @prepend_space @append_space @append_indent_start
  "end" @prepend_hardline @prepend_indent_end
)

;; =============================================================
;; 4. Control flow clauses — interrupt and restart indentation
;; =============================================================

;; For clauses that interrupt blocks, we close the parent indent,
;; add the clause keyword on a new line, then re-open indent for the body.

(if_statement
  alternative: (elseif_clause) @prepend_indent_end @prepend_hardline
)

(elseif_clause
  condition: (_) @append_hardline @append_indent_start
)

(if_statement
  alternative: (else_clause) @prepend_indent_end @prepend_hardline
)

(else_clause
  "else" @append_hardline @append_indent_start
)

(try_statement
  (catch_clause) @prepend_indent_end @prepend_hardline
)

;; Catch clause indentation: indent after catch keyword.
;; With variable (catch e): "catch" space "e" then body on next line
;;   (hardline between identifier and body comes from (_) . (_) pattern)
;; Without variable: "catch" then body on next line
(catch_clause
  "catch" @append_indent_start
)

(try_statement
  (finally_clause) @prepend_indent_end @prepend_hardline
)

(finally_clause
  "finally" @append_hardline @append_indent_start
)

;; =============================================================
;; 4b. Hardlines between body statements in blocks
;;     Without these, consecutive statements merge onto one line.
;;     We match consecutive named siblings — the second gets a hardline.
;; =============================================================

;; Generic: any two consecutive named children inside block-like parents.
;; The first child already has a hardline from the indent_start; we need
;; hardlines between the 2nd, 3rd, etc.

;; Append hardline to every named child in block-like parents.
;; Topiary deduplicates consecutive hardlines, so this is safe.
(source_file (_) @append_hardline)
(function_definition (_) @append_hardline)
(macro_definition (_) @append_hardline)
(struct_definition (_) @append_hardline)
(module_definition (_) @append_hardline)
(if_statement (_) @append_hardline)
(elseif_clause (_) @append_hardline)
(else_clause (_) @append_hardline)
;; For body: hardline after every child (bindings + body).
;; Multi-binding for loops get one binding per line with leading comma.
(for_statement (_) @append_hardline)
(while_statement (_) @append_hardline)
(try_statement (_) @append_hardline)
(catch_clause (_) @append_hardline)
(finally_clause (_) @append_hardline)
(compound_statement (_) @append_hardline)
(let_statement (_) @append_hardline)
(quote_statement (_) @append_hardline)
(do_clause (_) @append_hardline)

;; =============================================================
;; 4c. For-binding spacing (for x in collection)
;; =============================================================

;; "in", "=", "∈" are aliased to (operator) inside for_binding
(for_binding
  (operator) @prepend_space @append_space
)

;; Let bindings: = is aliased to (operator)
(let_binding
  (operator) @prepend_space @append_space
)

;; =============================================================
;; 4d. Catch clause — space after "catch" and before variable
;; =============================================================

(catch_clause
  (_) @prepend_space
  .
  (_)
)

;; =============================================================
;; 5. Operator spacing
;; =============================================================

;; Assignment
(assignment
  (operator) @prepend_space @append_space
)

;; Binary expressions
(binary_expression
  (operator) @prepend_space @append_space
)

;; Compound assignment (+=, -=, etc.)
(compound_assignment_expression
  (operator) @prepend_space @append_space
)

;; Ternary
(ternary_expression
  "?" @prepend_space @append_space
  ":" @prepend_space @append_space
)

;; Arrow functions
(arrow_function_expression
  "->" @prepend_space @append_space
)

;; Type annotation ::
(typed_expression
  "::" @prepend_antispace
)

;; Where clause: space before and after "where"
(where_expression
  "where" @prepend_space
)

;; =============================================================
;; 6. Argument lists and collections — softline formatting
;; =============================================================

;; Function argument lists
;; empty_softline: nothing in single-line, newline in multi-line
;; spaced_softline: space in single-line, newline in multi-line
(argument_list
  "(" @append_empty_softline @append_indent_start
  "," @append_spaced_softline
  ")" @prepend_empty_softline @prepend_indent_end
)

;; Semicolons in argument lists (keyword arg separator)
(argument_list
  ";" @append_spaced_softline
)

;; Named/keyword arguments: space around =
(named_argument
  (operator) @prepend_space @append_space
)

;; Tuple expressions
(tuple_expression
  "(" @append_empty_softline @append_indent_start
  "," @append_spaced_softline
  ")" @prepend_empty_softline @prepend_indent_end
)

;; Parenthesized expressions
(parenthesized_expression
  "(" @append_empty_softline @append_indent_start
  ")" @prepend_empty_softline @prepend_indent_end
)

;; Vector expressions
(vector_expression
  "[" @append_empty_softline @append_indent_start
  "," @append_spaced_softline
  "]" @prepend_empty_softline @prepend_indent_end
)

;; Curly expressions (type parameters)
(curly_expression
  "{" @append_empty_softline @append_indent_start
  "," @append_spaced_softline
  "}" @prepend_empty_softline @prepend_indent_end
)

;; Matrix expressions: spaces between row elements are SEMANTICALLY significant.
;; [a b c] is a 1x3 matrix row, [abc] is a 1-element vector.
;; We MUST preserve spaces between elements in matrix rows.
(matrix_row
  (_) @append_space
)

;; =============================================================
;; 7. Top-level / source file structure
;; =============================================================

;; Allow blank lines between top-level definitions and statements.
;; This preserves intentional visual grouping in the source.
(source_file (_) @allow_blank_line_before)
(module_definition (_) @allow_blank_line_before)
(function_definition (_) @allow_blank_line_before)
(if_statement (_) @allow_blank_line_before)
(for_statement (_) @allow_blank_line_before)
(while_statement (_) @allow_blank_line_before)
(try_statement (_) @allow_blank_line_before)

;; =============================================================
;; 8. Comments
;; =============================================================

(line_comment) @prepend_input_softline @append_hardline

(block_comment) @prepend_input_softline @append_hardline

;; =============================================================
;; 9. Import / using / export formatting
;; =============================================================

(selected_import
  ":" @append_space
  "," @append_space
)

;; Comma spacing in imports/exports
(import_statement "," @append_space)
(using_statement "," @append_space)
(export_statement "," @append_space)

;; Import alias: "as" already gets @append_space from keywords;
;; we need @prepend_space too
(import_alias
  "as" @prepend_space
)

;; NOTE: Relative import dots (import ..A) are stripped by Topiary because
;; the "." tokens in import_path are not addressable in queries for this
;; grammar version. This is a known limitation.

;; =============================================================
;; 10. Macro calls
;; =============================================================

;; Macro calls: @x(args), @x[args], @x{args} must NOT get a space
;; because it changes the AST. Only add space when the macro uses
;; space-separated arguments (macro_argument_list node).
(macrocall_expression
  (macro_identifier) @append_space
  .
  (macro_argument_list)
)

;; Space-separated macro arguments need spaces between them.
;; Without this, @foo a b becomes @foo ab.
(macro_argument_list
  (_) @append_space
)

;; =============================================================
;; 11. Comprehensions
;; =============================================================

;; for/if clauses inside comprehensions
(for_clause
  "for" @prepend_space @append_space
)
(if_clause
  "if" @prepend_space @append_space
)

;; =============================================================
;; 12. Let with empty body
;; =============================================================

;; When let has no bindings (just "let\nend"), the "let" keyword
;; already gets @append_space from keywords, and "end" gets
;; @prepend_hardline from the let_statement block rule. But if
;; there are no named children between let and end, we need to
;; make sure the let_statement rule still works.
