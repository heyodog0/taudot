// txp-render: txp-headless plus the renderer project's commands (docs/agents/renderer/README.md).
//
// It includes driver.c whole (our copy of the preview's txp-headless.c, dvi/README.md), so the preview protocol
// stays the same, and answers its own verbs first through the TXP_EXTRA_COMMANDS hook. Each verb lives in its own file, owned by one agent:
//   glyphs.c  the cursor agent: per-glyph boxes, text and source positions of a page
//   dlist.c   the backend agent: a page's vector display list for the Core Graphics renderer
// Build: ./build.sh

#define TXP_EXTRA_COMMANDS 1
#include "driver.c"

static bool cmd_glyphs(vstack *st, val cmd, int n);
static bool cmd_dlist(vstack *st, val cmd, int n);

#include "glyphs.c"
#include "dlist.c"

static bool txp_extra_command(vstack *st, val cmd, const char *verb, int n)
{
  if (strcmp(verb, "glyphs") == 0) return cmd_glyphs(st, cmd, n);
  if (strcmp(verb, "dlist") == 0) return cmd_dlist(st, cmd, n);
  return false;
}
