// How many characters delete_surrounding_text may remove before the cursor (#32). GNOME's mutter checks the delete
// against the text the app last reported (it never adds what we committed since) and aborts the whole session on a
// delete past its start (g_assert before >= start). cursor: the app's last reported cursor, -1 when none since focus_in.
#pragma once
#include <algorithm>
inline int surroundingDeleteCount(int n, int cursor) { return std::max(0, std::min(n, cursor)); }
