/// Which slice of the library the memories screen is showing.
///
/// Shared by the screen and the chips that set them, so neither owns the other.
library;

enum MemoriesTab { moments, highlights }

enum MemoryFilter {
  all,
  pinned,
  thisWeek,
  meetings,
  decisions,
  openTasks,
  archived,
}
