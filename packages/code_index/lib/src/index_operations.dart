/// Removed in the v2 rewrite. The v1 per-file `auto-index` write path
/// (`IndexOperations.autoIndex`) is replaced by the batched `index-files`
/// operation in `write_operations.dart`; layer-0 normalization lives in
/// `record_normalize.dart` and the §8.5 dependent refresh in
/// `reference_refresh.dart`. This file is intentionally empty and is no longer
/// exported from the `code_index` barrel — delete it once the working tree
/// permits (no file-delete tool was available when it was emptied).
library;
