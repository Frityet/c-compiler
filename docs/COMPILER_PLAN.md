# In-Depth Plan for Building a C Compiler

This document outlines a staged approach for developing a C compiler using the scaffold in this repository. Each phase lists goals, deliverables, and recommended source locations using the `src/` and `include/` directories.

## 1. Project Setup
- **Toolchain**: Ensure `gcc` and build tools are installed via `setup.sh`.
- **Directory Structure**: Keep compiler sources in `src/` and headers in `include/`. Tests live in `tests/` and new scripts go in `docs/` or other relevant directories.
- **Build System**: Use the provided `Makefile` to compile to `bin/cc`. Extend it as new modules appear.

## 2. Lexical Analysis
- **Goal**: Convert raw C source text into a stream of tokens.
- **Tasks**:
  - Define token types (identifiers, keywords, literals, operators) in `include/token.h`.
  - Implement a lexer in `src/lexer.c` that reads characters and outputs tokens while tracking line/column information for error reporting.
  - Add tests covering basic tokenization in `tests/`.

## 3. Parsing
- **Goal**: Build an abstract syntax tree (AST) from the token stream.
- **Tasks**:
  - Design AST node structures in `include/ast.h`.
  - Implement a recursive-descent or table-driven parser in `src/parser.c`.
  - Support parsing of expressions, statements, function definitions, and declarations.
  - Write parser tests for valid and invalid inputs.

## 4. Semantic Analysis
- **Goal**: Validate the AST for type correctness and symbol resolution.
- **Tasks**:
  - Create symbol table data structures in `include/symbol.h` and implement them in `src/symbol.c`.
  - Perform type checking, scope resolution, and report semantic errors.
  - Implement constant folding or simple optimizations at this stage if desired.

## 5. Intermediate Representation (IR)
- **Goal**: Translate the AST into a lower-level representation suited for optimization and code generation.
- **Tasks**:
  - Design an IR in `include/ir.h` (e.g., three-address code or basic blocks).
  - Implement AST-to-IR translation in `src/irgen.c`.
  - Provide tests ensuring the IR matches expected output for sample programs.

## 6. Optimization (Optional Early Stages)
- **Goal**: Improve the IR before emitting machine code.
- **Tasks**:
  - Implement simple optimizations such as dead-code elimination and constant propagation in `src/opt.c`.
  - Ensure optimizations preserve program semantics with dedicated tests.

## 7. Code Generation
- **Goal**: Produce assembly or machine code from the IR.
- **Tasks**:
  - Decide on an output format (e.g., x86-64 assembly).
  - Implement a backend in `src/codegen.c` that converts IR instructions into assembly.
  - Integrate with the system assembler and linker via the `Makefile` to produce executables.

## 8. Linking and Runtime Support
- **Goal**: Link compiled object files with necessary runtime components.
- **Tasks**:
  - Provide startup code and standard library hooks if needed.
  - Generate object files with position-independent code where appropriate.
  - Ensure the final executable runs on the target platform.

## 9. Testing and Continuous Integration
- **Goal**: Keep the compiler reliable as it evolves.
- **Tasks**:
  - Expand the test suite in `tests/` to cover each new feature.
  - Update `run_tests.sh` to build and run the entire suite automatically.
  - Consider integrating with CI pipelines to run tests on every change.

## 10. Error Handling and Diagnostics
- **Goal**: Provide clear, user-friendly error messages.
- **Tasks**:
  - Include line and column numbers in diagnostic output from each stage.
  - Emit warnings for suspicious constructs and offer helpful hints.

## 11. Future Extensions
- **Ideas**:
  - Implement optimization passes such as register allocation or loop unrolling.
  - Target additional architectures by creating new code generation modules.
  - Add support for standard library headers and system calls.

---

This plan should evolve alongside the codebase. Each completed phase should leave behind thorough tests and documentation, ensuring the compiler grows in a manageable and maintainable way.
