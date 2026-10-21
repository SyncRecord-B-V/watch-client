# watch_client wiki sources

This folder holds the pages of the GitHub wiki for watch_client
(`https://github.com/SyncRecord-B-V/watch-client/wiki`). One Markdown file is one wiki page. The file name is the
page name: `Installation-in-Rails.md` becomes the page "Installation in Rails". `Home.md` is the start page and
`_Sidebar.md` is the sidebar on every page. Links between pages use the wiki style `[Text](Page-Name)`, without `.md`.
This README is not a wiki page; do not copy it.

## Publish with Git

The wiki must exist first: open the repository's **Wiki** tab on GitHub and save any first page once.

```bash
git clone https://github.com/SyncRecord-B-V/watch-client.wiki.git
cd watch-client.wiki
rsync -av --exclude README.md ../watch-client/docs/wiki/ ./   # adjust the path to your checkout
git add .
git commit -m "Update watch_client wiki for 0.10.0"
git push
```

Pages that exist in the wiki but not in this folder are kept. Delete them by hand if they are outdated.

## Publish page by page

1. Open the wiki on GitHub and click **New Page** (or **Edit** on an existing page).
2. Use the file name without `.md` as the title, with spaces or hyphens (`Quick Start` or `Quick-Start`).
3. Paste the file's content and save.
4. For the sidebar, click **Add a custom sidebar** and paste `_Sidebar.md`.

## Keep it accurate

The pages describe gem version 0.10.0 and were checked against `lib/` and `test/`. When the code changes, update the
page that describes it, and `Changelog.md` when `CHANGELOG.md` changes. Use placeholder values in examples, never
real keys.
