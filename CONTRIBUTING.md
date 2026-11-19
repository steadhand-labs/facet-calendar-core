# Contributing

Run `dart pub get`, `dart analyze --fatal-infos` and `dart test` before opening a pull request.

Changes that touch Markdown parsing or editing must include the exact input text and the exact
expected output in a test. The core promise is that an edit changes only the bytes it targets, so
tests compare whole files byte for byte. Use a temporary folder for any vault a test creates.

To replay a fuzzer failure, rerun with the `FACET_FUZZ_SEED` and `FACET_FUZZ_CASES` values it prints.

Contributions are accepted under the [MIT license](LICENSE).
