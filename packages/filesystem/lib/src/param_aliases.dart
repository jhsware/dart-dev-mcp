/// Tolerant reading of line-number tool arguments.
///
/// The filesystem tool's line parameters have historically mixed naming
/// conventions (`startLine`/`endLine` camelCase, `insert_at` snake_case).
/// Callers regularly guess the other convention, and for `edit-file` an
/// ignored line parameter is destructive: the call falls through to the
/// no-line-params default and overwrites the entire file. These helpers
/// accept both spellings and detect near-miss spellings so they fail
/// loudly instead of silently.
library;

/// Canonical + alias spellings for each line parameter.
const Map<String, List<String>> lineParamSpellings = {
  'startLine': ['startLine', 'start_line'],
  'endLine': ['endLine', 'end_line'],
  'insert_at': ['insert_at', 'insertAt'],
};

/// Read an integer argument from [args], accepting any of the recognized
/// [lineParamSpellings] for [canonical]. Earlier spellings win when several
/// are present.
int? lineArg(Map<String, dynamic> args, String canonical) {
  for (final name in lineParamSpellings[canonical] ?? [canonical]) {
    final value = args[name];
    if (value is num) return value.toInt();
  }
  return null;
}

String _normalizeKey(String key) =>
    key.toLowerCase().replaceAll(RegExp(r'[_-]'), '');

/// Return the first argument key that looks like a line parameter
/// (normalizes to `startline`, `endline`, or `insertat`) but is not one of
/// the recognized spellings — or null when every key is fine.
///
/// `edit-file` treats "no line params" as "overwrite the whole file", so a
/// misspelled line parameter must produce a validation error rather than
/// being silently ignored.
String? unrecognizedLineParam(Map<String, dynamic> args) {
  final recognized = lineParamSpellings.values.expand((s) => s).toSet();
  final lineParamForms =
      lineParamSpellings.values.expand((s) => s).map(_normalizeKey).toSet();

  for (final key in args.keys) {
    if (recognized.contains(key)) continue;
    if (lineParamForms.contains(_normalizeKey(key))) return key;
  }
  return null;
}
