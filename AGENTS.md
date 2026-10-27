# AGENTS Rules

## Test Style

- Always write `vm.prank(user); action();` on a single line, exactly in this style.
- Use `assertEq` for exact value checks in tests.
- Keep test names descriptive and in `snake_case` style.
- Use `makeAddr("...")` for deterministic test user addresses.
- Prefer concrete numeric values in assertions instead of intermediate test variables.
- Optionally add a short formula comment when a value is not obvious.

## Solidity Style

- Keep contract logic minimal, explicit, and easy to audit.

## Documentation Style

- Do not write specs for state variables, methods, interfaces, libraries and contracts. Keep codebase clean and not noisy.
- You may and should add notes with explanations (not descriptions) for functions with complex logic.
- Add explanatory notes for complex mathematical calculations.

