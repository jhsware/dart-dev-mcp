/// Tolerant reading of line-number tool arguments.
///
/// The filesystem tool's line parameters have historically mixed naming
/// conventions (`startLine`/`endLine` camelCase, `insert_at` snake_case).
/// Callers regularly guess the other convention, and for `edit-file` an
/// ignored line parameter is destructive. [lineArg] accepts both spellings;
/// spellings outside [lineParamSpellings] are rejected by the dispatcher's
/// per-operation unknown-argument check (`checkUnknownArgs` in shared_libs).
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
