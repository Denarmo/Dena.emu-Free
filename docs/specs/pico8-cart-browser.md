# Spec: PICO-8 cart browser

Status: implemented and **on** (Milestone 3, package 10b; enabled 2026-10-17)

## The flag

Lexaloffle publishes no rule requiring permission for a third-party player or
cart browser (checked 2026-10-17, sources in docs/provenance.md), so the user
turned `pico8BrowserEnabled` (in `app/lib/src/library/carts_tab.dart`) on. It
stays as a kill switch: off, the Carts tab is import only (pico8.md). It also
gates browsing and downloading inside the Dena Explore launcher cart
(pico8-launcher-cart.md); off, the cart lists library carts only. Nobody on the
project contacts Lexaloffle except the user.

Licenses: each BBS cart carries a license its author chose, most often
CC4-BY-NC-SA. The listing data does not include it, so the details sheet says
the license is on the cart's BBS page and links there. Because many carts are
non-commercial, browsing and downloading stay free. Nothing says or suggests Dena.emu is official PICO-8.

## Rules

- Never rehost carts or thumbnails. The app fetches each cart and thumbnail
  directly from the BBS when the user asks, and keeps nothing on our servers.
- Every cart shows its title and **author**; its details show a link to its BBS
  thread. The author is credited again when the download finishes.
- No scraping in the background: requests happen only for the tab, page or cart
  the user opened.

## Data source (`app/lib/src/carts/bbs.dart`)

`BbsClient` is the interface; `HttpBbsClient` talks to the BBS and
`FakeBbsClient`-style test doubles read fixtures. Tests never hit the network.

| Query | BBS listing URL (`https://www.lexaloffle.com/bbs/`) |
| --- | --- |
| Featured | `?cat=7&sub=2&orderby=featured&page=N` |
| New | `?cat=7&sub=2&orderby=ts&page=N` |
| Search | `?cat=7&sub=2&search=<text>&page=N` |
| By author | `?cat=7&sub=2&uid=<id>&mode=carts&page=N` |

The listing page carries one row per post in a script array. A row starts
`['<post id>', <thread id>, `<title>`, "<thumb path>", w, h, "<created>",
<author id>, "<author name>", "<updated>", …`; `parseBbsListing` reads those
fields and ignores the rest. Unknown or malformed rows are skipped, never fatal.
A page with 30 rows is assumed to have a next page.

- Cart id: the thumb file name without `pico8_` and `.png`
  (`/bbs/thumbs/pico8_foo-3.png` → `foo-3`).
- Cart file: `/bbs/cposts/<first two chars of id>/<id>.p8.png`; a numeric id
  `n` uses `/bbs/cposts/<n ÷ 10000>/<n>.p8.png`.
- Thread link: `https://www.lexaloffle.com/bbs/?tid=<thread id>`.
- Titles and names decode the HTML entities `&amp; &lt; &gt; &quot; &#39; &#NN;`.

Errors: no connection, timeout or a non-200 reply → `BbsException` with a
short user-facing message. A cart download that isn't a PNG is rejected.

## Screen (`app/lib/src/carts/cart_browser.dart`)

Opened from the Carts tab's "Browse the BBS" card (only when the flag is on).
A full-screen page with an app bar ("PICO-8 BBS") and four tabs:

1. **Featured** — featured carts, newest first page.
2. **New** — most recently posted carts.
3. **Search** — a text field; Enter / the search key runs the query.
   Empty field: a hint, no request.
4. **Authors** — authors of the carts loaded so far (Featured and New),
   alphabetical; selecting one shows that author's carts (back returns).

Each list is a `BrutalTable` of carts (label thumbnail, FILE_STYLE title,
author); tabs are a `BrutalTabBar` (brutalist-ui.md 4.7).
The end of a list shows a "Load more" button when there is a next page.

Selecting a row opens a details `BrutalSheet` (one button always focused): thumbnail, title, author, the thread
link, and buttons **Download** (or **In library** when the cart's file is
already imported, disabled), **More by author**, **Copy link**.

### Download

One tap: fetch `<id>.p8.png`, write it to a temporary `<title>.p8.png`, import
it with the normal importer (it lands in the library's `pico8` folder, the
Carts folder on handhelds), then delete the temporary file. A snackbar says
"Added <title> by <author>" or "Already in your library". The cart's credit
(author, thread id, cart id) is saved by SHA-1 in `<data dir>/carts/credits.json`
for later display. A failed download shows the error and changes nothing.

### States

- Loading: a progress indicator in the tab body.
- Offline / error: an icon, the message and a **Retry** button (focused).
- Empty result: "No carts found".

### Input

- Touch: tap tabs, cards and buttons; Back closes the page.
- D-pad: arrows move focus with a visible ring; A / Enter selects; B / Escape
  goes back; **L1 / R1 switch tabs** (they wrap). The first card of a list
  takes focus when it loads.
- Handhelds show a hint bar: A Select, L1/R1 Tabs, B Back.

### Layout

Designed for 640×480 first; the same table on every size, columns drop or
ellipsize on narrow phones. The Carts tab itself is a table (`#`, CART, TITLE,
AUTHOR, LICENSE, FAV) with Dena Explore pinned as row `00` under a primary
`[LAUNCH EXPLORE]` button.

## Acceptance tests

- Parser (`test/carts/bbs_test.dart`): a synthetic listing fixture (our own
  invented carts) parses titles, authors, ids, entities; bad rows are skipped;
  URL builders for every query, numeric and string cart ids, thread links.
- Widget (`test/carts/cart_browser_test.dart`) with a fixture-backed fake client:
  - every tab renders at 640×480, 720×720 and phone, touch and focus modes;
    goldens for Featured and the error state;
  - L1 / R1 cycle Featured → New → Search → Authors → Featured;
  - an error shows Retry, and Retry reloads;
  - Search runs only on submit and shows results;
  - Authors lists unique authors; selecting one shows their carts;
  - Download imports the cart into the library as PICO-8, credits the author
    and saves the credit; a second download says it is already there;
  - Escape closes the details sheet and the page.
- Carts tab: with the flag off there is no browse button (existing behaviour);
  with it forced on in a test, the button opens the browser.
