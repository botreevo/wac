// Admission, as the page sees it: a subject and settings in, `{ code, cid, lines }` out, `code` as `claim admit`'s
// exit code (0 admitted). It will run cmd/web.wac, built with wac's --target browser, in a worker, and that worker
// will write the admitted tree into OPFS (tree.js) from blocks it checked.
//
// **Not built yet**: wac cannot build cmd/web.wac for a page (W2a) or give it HTTP (W1); see
// docs/browser-extension.md. Until then every subject is refused, saying why, and nothing is shown.

export async function admit(settings, subject, role) {
  return {
    code: 3,
    cid: null,
    lines: [
      `${subject} as ${role}: not decided.`,
      'Admission is not built into the extension yet: it waits on wac building cmd/web.wac for a page and giving it HTTP.',
      'Nothing is shown that was not admitted.',
      'REFUSED',
    ],
  };
}
