;; topiary-julia formatting queries (tree-sitter-julia v0.25.0)
;; =============================================================
;; 1. Leaf nodes — preserve content as-is
;; =============================================================

[
  (string_literal)
  (prefixed_string_literal)
  (command_literal)
  (prefixed_command_literal)
  (character_literal)
  (identifier)
  (var_identifier)
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
  "public"
  "const"
  "local"
  "global"
  "outer"
  "as"
  "where"
] @append_space

;; =============================================================
;; 3. Block indentation — keyword...end constructs
;;    In v0.25.0, block bodies are wrapped in a (block) node.
;;    Pattern: indent after opening line, de-indent before "end".
;; =============================================================

;; --- function / macro ---

;; Non-empty function: indent block
(function_definition
  (signature) @append_hardline @append_indent_start
  (block)
  "end" @prepend_hardline @prepend_indent_end
)
;; Empty function: keep single-line (function f end, function f() end)
(function_definition
  (signature) @append_space
  .
  "end"
)
(source_file (function_definition) @append_hardline)
(block (function_definition) @append_hardline)

(macro_definition
  (signature) @append_hardline @append_indent_start
  (block)
  "end" @prepend_hardline @prepend_indent_end
)
(macro_definition
  (signature) @append_space
  .
  "end"
)
(source_file (macro_definition) @append_hardline)
(block (macro_definition) @append_hardline)

;; --- struct ---

(struct_definition
  (type_head) @append_hardline @append_indent_start
  (block)
  "end" @prepend_hardline @prepend_indent_end
)
(struct_definition
  (type_head) @append_space
  .
  "end"
)
(source_file (struct_definition) @append_hardline)
(block (struct_definition) @append_hardline)

;; --- module ---

;; Module bodies are NOT indented (Julia convention, matches Runic/JuliaFormatter)
(module_definition
  name: (_)
  "end" @prepend_hardline
)
(module_definition
  (block) @prepend_hardline
)
(source_file (module_definition) @append_hardline)
(block (module_definition) @append_hardline)

;; --- abstract / primitive type ---
;; Single-line: `abstract type T end`, `primitive type T 64 end`

(abstract_definition
  (type_head) @append_space
  "end"
)
(source_file (abstract_definition) @append_hardline)
(block (abstract_definition) @append_hardline)

(primitive_definition
  (type_head) @append_space
  (integer_literal) @append_space
  "end"
)
(source_file (primitive_definition) @append_hardline)
(block (primitive_definition) @append_hardline)

;; --- if ---

(if_statement
  condition: (_) @append_hardline @append_indent_start
  "end" @prepend_hardline @prepend_indent_end
)
;; Hardline AFTER if_statement only when it's a statement (child of source_file
;; or block), not when it's part of a larger expression like (if ... end)::Bool.
(source_file (if_statement) @append_hardline)
(block (if_statement) @append_hardline)

;; --- for ---

(for_statement
  "for" @append_indent_start
  "end" @prepend_hardline @prepend_indent_end
)
(source_file (for_statement) @append_hardline)
(block (for_statement) @append_hardline)

;; --- while ---

(while_statement
  condition: (_) @append_hardline @append_indent_start
  "end" @prepend_hardline @prepend_indent_end
)
(source_file (while_statement) @append_hardline)
(block (while_statement) @append_hardline)

;; --- try ---

(try_statement
  "try" @append_indent_start
  "end" @prepend_hardline @prepend_indent_end
)
(try_statement
  (block) @prepend_hardline
)
(source_file (try_statement) @append_hardline)
(block (try_statement) @append_hardline)

;; --- begin / let / quote ---

(compound_statement
  "begin" @append_hardline @append_indent_start
  "end" @prepend_hardline @prepend_indent_end
)
(source_file (compound_statement) @append_hardline)
(block (compound_statement) @append_hardline)

(let_statement
  "let" @append_indent_start
  "end" @prepend_hardline @prepend_indent_end
)
(source_file (let_statement) @append_hardline)
(block (let_statement) @append_hardline)

(quote_statement
  "quote" @append_hardline @append_indent_start
  "end" @prepend_hardline @prepend_indent_end
)
(source_file (quote_statement) @append_hardline)
(block (quote_statement) @append_hardline)

;; --- do clause ---

(do_clause
  "do" @prepend_space @append_space @append_indent_start
  "end" @prepend_hardline @prepend_indent_end
)

;; =============================================================
;; 4. Control flow clauses — interrupt and restart indentation
;; =============================================================

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
;; 4b. Statement separation
;;     In v0.25.0, all block bodies are inside visible (block) nodes.
;;     We use @append_hardline for reliable separation (fires on every child).
;;     For for/let bindings, we also use @prepend_hardline to keep
;;     commas on the correct line.
;; =============================================================

;; Inside blocks: hardline after each statement
(block (_) @append_hardline)

;; Top-level: hardline after each item
(source_file (_) @append_hardline)

;; Semicolons as statement separators: delete them.
;; They're replaced by hardlines from the rules above.
;; Only in statement/block contexts — NOT in argument_list, tuple, paren, etc.
(source_file ";" @delete)
(block ";" @delete)
(while_statement ";" @delete)
(for_statement ";" @delete)
(if_statement ";" @delete)
(elseif_clause ";" @delete)
(else_clause ";" @delete)
(try_statement ";" @delete)
(catch_clause ";" @delete)
(finally_clause ";" @delete)
(function_definition ";" @delete)
(struct_definition ";" @delete)
(module_definition ";" @delete)
(let_statement ";" @delete)
(compound_statement ";" @delete)
(macro_definition ";" @delete)
(do_clause ";" @delete)
(quote_statement ";" @delete)

;; For/let: hardline before block, comma spacing for multi-binding.
(for_statement (block) @prepend_hardline)
(for_statement "," @append_space)
(let_statement (block) @prepend_hardline)
(let_statement "," @append_space)

;; Do clause: hardline before block, comma spacing for parameters.
(do_clause (block) @prepend_hardline)
(do_clause "," @append_space)

;; Catch: ensure hardline before block even when no identifier
(catch_clause (block) @prepend_hardline)


;; =============================================================
;; 4c. For-binding spacing (for x in collection)
;; =============================================================

(for_binding
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

(assignment
  (operator) @prepend_space @append_space
)

(binary_expression
  (operator) @prepend_space @append_space
)

(compound_assignment_expression
  (operator) @prepend_space @append_space
)

(ternary_expression
  "?" @prepend_space @append_space
  ":" @prepend_space @append_space
)

(arrow_function_expression
  "->" @prepend_space @append_space
)

;; Unary operator + paren/tuple: preserve space to prevent AST change
(unary_expression
  (operator) @append_space
  .
  (tuple_expression)
)
(unary_expression
  (operator) @append_space
  .
  (parenthesized_expression)
)

;; Type annotation ::
(typed_expression
  "::" @prepend_antispace
)

;; Where clause
(where_expression
  "where" @prepend_space
)

;; =============================================================
;; 6. Argument lists and collections
;; =============================================================

(argument_list
  "(" @append_empty_softline @append_indent_start
  ")" @prepend_empty_softline @prepend_indent_end
)
(argument_list
  "," @append_spaced_softline
)

(argument_list
  ";" @append_spaced_softline
)
;; Consecutive semicolons (;;): prevent space between them.
(argument_list ";" . ";" @prepend_antispace)

;; Named/keyword arguments use (assignment) in v0.25.0, already handled above.

(tuple_expression
  "(" @append_empty_softline @append_indent_start
  ")" @prepend_empty_softline @prepend_indent_end
)
(tuple_expression
  "," @append_spaced_softline
)
;; Remove space before ) when preceded by trailing comma: (a,) not (a, )
(tuple_expression "," . ")" @prepend_antispace)
(argument_list "," . ")" @prepend_antispace)

(parenthesized_expression
  "(" @append_empty_softline @append_indent_start
  ")" @prepend_empty_softline @prepend_indent_end
)

(vector_expression
  "[" @append_empty_softline @append_indent_start
  "]" @prepend_empty_softline @prepend_indent_end
)
(vector_expression
  "," @append_spaced_softline
)

(curly_expression
  "{" @append_empty_softline @append_indent_start
  "}" @prepend_empty_softline @prepend_indent_end
)
(curly_expression
  "," @append_spaced_softline
)

;; Matrix expressions: content is semantically significant.
(matrix_expression) @leaf

;; Bracescat: curly expressions with space/semicolon-separated elements.
;; Spaces are semantic (like matrix expressions), so preserve as @leaf.
(curly_expression (matrix_row)) @leaf

;; =============================================================
;; 7. Top-level / source file structure
;; =============================================================

(source_file (_) @allow_blank_line_before)
(module_definition (_) @allow_blank_line_before)
(block (_) @allow_blank_line_before)

;; =============================================================
;; 8. Comments
;; =============================================================

(line_comment) @prepend_input_softline @append_hardline
(block_comment) @prepend_input_softline @append_hardline

;; Open tuples (implicit, no parens): a, b, c
(open_tuple
  "," @append_space
)

;; =============================================================
;; 9. Import / using / export formatting
;; =============================================================

(selected_import
  ":" @append_space
  "," @append_space
)

(import_statement "," @append_space)
(using_statement "," @append_space)
(export_statement "," @append_space)
(public_statement "," @append_space)

(import_alias
  "as" @prepend_space
)

(import_path) @leaf

;; =============================================================
;; 10. Macro calls
;; =============================================================

(macrocall_expression
  (macro_identifier) @append_space
  .
  (macro_argument_list)
)

;; Qualified macro calls: A.@foo a b
(macrocall_expression
  (field_expression) @append_space
  .
  (macro_argument_list)
)

(macro_argument_list
  (_) @append_space
)

;; =============================================================
;; 11. Comprehensions
;; =============================================================

(for_clause
  "for" @prepend_space @append_space
)
(for_clause
  "," @append_space
)
(if_clause
  "if" @prepend_space @append_space
)
