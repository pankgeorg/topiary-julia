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
  "do"
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

(abstract_definition
  "end" @prepend_hardline @prepend_indent_end @append_hardline
)
(abstract_definition
  (type_head) @append_hardline @append_indent_start
)

(primitive_definition
  "end" @prepend_hardline @prepend_indent_end @append_hardline
)

;; --- if ---

(if_statement
  condition: (_) @append_hardline @append_indent_start
  "end" @prepend_hardline @prepend_indent_end @append_hardline
)

;; --- for ---

(for_statement
  (for_binding) @append_hardline @append_indent_start
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

;; let with bindings: bindings stay on same line, body indented below
(let_statement
  (let_binding) @append_hardline @append_indent_start
  "end" @prepend_hardline @prepend_indent_end @append_hardline
)

(quote_statement
  "quote" @append_hardline @append_indent_start
  "end" @prepend_hardline @prepend_indent_end @append_hardline
)

;; --- do clause ---

(do_clause
  "do" @append_hardline @append_indent_start
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

;; =============================================================
;; 6. Argument lists and collections — softline formatting
;; =============================================================

;; Function argument lists
(argument_list
  "(" @append_spaced_softline @append_indent_start
  "," @append_spaced_softline
  ")" @prepend_spaced_softline @prepend_indent_end
)

;; Tuple expressions
(tuple_expression
  "(" @append_spaced_softline @append_indent_start
  "," @append_spaced_softline
  ")" @prepend_spaced_softline @prepend_indent_end
)

;; Parenthesized expressions
(parenthesized_expression
  "(" @append_spaced_softline @append_indent_start
  ")" @prepend_spaced_softline @prepend_indent_end
)

;; Vector expressions
(vector_expression
  "[" @append_spaced_softline @append_indent_start
  "," @append_spaced_softline
  "]" @prepend_spaced_softline @prepend_indent_end
)

;; Curly expressions (type parameters)
(curly_expression
  "{" @append_spaced_softline @append_indent_start
  "," @append_spaced_softline
  "}" @prepend_spaced_softline @prepend_indent_end
)

;; =============================================================
;; 7. Top-level / source file structure
;; =============================================================

;; Allow blank lines between top-level definitions
(source_file
  [
    (function_definition)
    (macro_definition)
    (struct_definition)
    (abstract_definition)
    (primitive_definition)
    (module_definition)
  ] @allow_blank_line_before
)

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

;; =============================================================
;; 10. Macro calls
;; =============================================================

;; Space-separated macro calls: @assert x, @testset "a" begin...
;; The macro_identifier is followed by arguments.
(macrocall_expression
  (macro_identifier) @append_space
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
