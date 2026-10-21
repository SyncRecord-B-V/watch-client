# Browser Errors and Page Speed

The `watch_tag` view helper adds `watch.js` to your pages. The script is served by Watch, has no dependencies and is
about 5 KB gzipped. It reports JavaScript errors and unhandled promise rejections, and measures the page speed of
real visits (Core Web Vitals). It needs a browser key. Page speed needs the Team or Business plan in Watch.

## Setup

1. In Watch, on the app's **Edit** page, copy the browser key (`lhb_...`) and list the websites allowed to use it.
2. Set it where the app runs:

   ```bash
   WATCH_BROWSER_KEY=lhb_your_browser_key_here
   ```

   The browser key is public by design. It only allows sending browser errors and page speed from the listed websites.
3. Add the tag to the `<head>` of your layout(s):

   ```erb
   <%= watch_tag %>
   <%# or, so errors show which user saw them (an id, not personal data): %>
   <%= watch_tag(user_id: current_user&.id) %>
   ```

`watch_tag` also takes `environment:` and `version:` to override the configured values. It renders nothing when
`WATCH_URL` or the browser key is missing, when the URL is not allowed (plain `http://` to a remote host), or in the
`test` environment. Force it with `config.browser_enabled = true` or `false`.

The rendered tag looks like this:

```html
<script src="https://watch.syncrecord.com/watch.js" data-key="lhb_your_browser_key_here"
        data-environment="production" data-version="a1b2c3d4e5f6" data-user-id="42" nonce="..." defer></script>
```

## Content Security Policy

The tag gets the request's CSP nonce automatically (`content_security_policy_nonce`). Allow Watch in `script-src`
and `connect-src`:

```ruby
# config/initializers/content_security_policy.rb
policy.script_src  :self, "https://watch.syncrecord.com"
policy.connect_src :self, "https://watch.syncrecord.com"
```

## What watch.js sends

- **Errors:** uncaught errors and unhandled promise rejections, with breadcrumbs: clicks (buttons and links only,
  never what was typed), page changes, console errors and failed requests. At most 10 reports per page.
- **Page speed:** LCP, INP, CLS, FCP, TTFB and load time, once per page view. The page path has ids replaced
  (`/invoices/:id`); query strings are not sent.
- **URLs:** query values that look secret or personal are masked. Add `data-watch-mask` to an element to hide its text
  in click breadcrumbs.

## Page speed settings

```ruby
config.browser_vitals = false       # errors only, no page speed
config.vitals_sample_rate = 0.25    # measure a quarter of page views
```

## In the browser

```js
WatchClient.notify(error, { context: { cartId: 7 } })  // report a caught error
WatchClient.setUser({ id: 42 })                         // who saw it
WatchClient.setContext({ plan: "pro" })                 // extra details on every report
WatchClient.addBreadcrumb("Opened checkout", { step: 2 })
```

Test from the browser console: `WatchClient.notify(new Error("Test from the console"))`.
