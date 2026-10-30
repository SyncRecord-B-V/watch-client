/*! watch.js 2.1.0: JavaScript errors and page speed for Watch (watch.syncrecord.com). No dependencies.
 *
 * <script src="https://watch.syncrecord.com/watch.js" data-key="lhb_..." data-environment="production"
 *         data-version="abc123" data-user-id="42" defer></script>
 *
 * Or from the app's own website, relayed by watch-php or watch_client (works where watch.syncrecord.com is blocked):
 * <script src="/watch/watch.js" data-key="lhb_..." data-endpoint="/watch/browser_errors" defer></script>
 *
 * Catches uncaught errors and unhandled promise rejections and sends them, with the
 * last steps before the error (clicks, page changes, console errors, failed requests),
 * to Watch. Also:
 *   WatchClient.notify(error, { context: { cartId: 7 } })   report a caught error
 *   WatchClient.setUser({ id: 42 })                         who saw it (an id, not personal data)
 *   WatchClient.setContext({ plan: "pro" })                 extra details on every report
 *   WatchClient.addBreadcrumb("Opened checkout", { step: 2 })
 * Page speed: Core Web Vitals of real visits (LCP, INP, CLS, FCP, TTFB, load), sent once per page view.
 *   data-vitals="false" turns it off; data-vitals-sample="0.25" measures a quarter of page views.
 * Settings can also come from window.WatchClientConfig = { key, endpoint, environment, version, userId, vitals, vitalsSample }.
 */
(function () {
  "use strict";
  if (window.WatchClient && window.WatchClient.version) return;

  var VERSION = "2.1.0";
  var MAX_BREADCRUMBS = 30;
  var MAX_REPORTS_PER_PAGE = 10;
  // Query values masked in every URL sent: secrets and values that usually identify a person.
  var SECRET_PARAM = /token|secret|password|passwd|key|auth|session|signature|code|e?mail|name|phone|tel|address|iban|zip|postcode|birth/i;

  var script = document.currentScript;
  var data = (script && script.dataset) || {};
  var preset = window.WatchClientConfig || {};
  var config = {
    key: preset.key || data.key,
    endpoint: absolute(preset.endpoint || data.endpoint) || defaultEndpoint(),
    environment: preset.environment || data.environment || "production",
    version: preset.version || data.version || null,
    enabled: preset.enabled !== false && data.enabled !== "false",
    // Page speed of real visits (Core Web Vitals); vitalsSample: share of page views measured (0-1).
    vitals: preset.vitals !== false && data.vitals !== "false",
    vitalsSample: parseFloat(preset.vitalsSample != null ? preset.vitalsSample : (data.vitalsSample || "1"))
  };
  var user = {};
  if (preset.userId || data.userId) user.id = String(preset.userId || data.userId);
  var context = {};
  var breadcrumbs = [];
  var sent = 0;
  var seen = {};

  // "/watch/browser_errors" (the app's own relay) -> "https://shop.example.com/watch/browser_errors".
  function absolute(url) {
    if (!url) return null;
    try {
      return new URL(url, window.location.href).toString();
    } catch (e) {
      return url;
    }
  }

  function defaultEndpoint() {
    try {
      return new URL("/api/v1/browser_errors", script.src).toString();
    } catch (e) {
      return null;
    }
  }

  function now() {
    return new Date().toISOString();
  }

  function truncate(value, max) {
    value = String(value == null ? "" : value);
    return value.length > max ? value.slice(0, max) + "…" : value;
  }

  // Masks secret-looking and personal query values (tokens, emails, names...) in URLs.
  function cleanUrl(url) {
    try {
      var parsed = new URL(url, location.href);
      parsed.searchParams.forEach(function (value, name) {
        if (SECRET_PARAM.test(name)) parsed.searchParams.set(name, "[FILTERED]");
      });
      parsed.hash = "";
      return parsed.toString();
    } catch (e) {
      return truncate(url, 500);
    }
  }

  function addBreadcrumb(category, message, metadata) {
    var crumb = { at: now(), category: category, message: truncate(message, 300) };
    if (metadata) crumb.metadata = metadata;
    breadcrumbs.push(crumb);
    if (breadcrumbs.length > MAX_BREADCRUMBS) breadcrumbs.shift();
  }

  function describe(element) {
    if (!element || !element.tagName) return "";
    var text = element.tagName.toLowerCase();
    if (element.id) text += "#" + element.id;
    if (typeof element.className === "string" && element.className.trim()) {
      text += "." + element.className.trim().split(/\s+/).slice(0, 2).join(".");
    }
    // Only the label of buttons and links, never what someone typed or picked in a field (GDPR:
    // form values are personal data). Add data-watch-mask to an element to hide its text too.
    var tag = element.tagName.toLowerCase();
    var isButton = tag === "button" || tag === "a" || element.getAttribute("role") === "button" ||
      (tag === "input" && /^(submit|button|reset)$/i.test(element.type || ""));
    if (!isButton || (element.closest && element.closest("[data-watch-mask]"))) return text;
    var label = (element.getAttribute("aria-label") || (tag === "input" ? element.value : element.innerText) || "").trim();
    if (label) text += ' "' + truncate(label.replace(/\s+/g, " "), 40) + '"';
    return text;
  }

  function errorFrom(value) {
    if (value instanceof Error) return value;
    if (value && typeof value === "object" && value.message) {
      var copy = new Error(String(value.message));
      copy.name = value.name || "Error";
      copy.stack = value.stack;
      return copy;
    }
    var error = new Error(typeof value === "string" ? value : safeJson(value));
    error.name = "NonError";
    return error;
  }

  function safeJson(value) {
    try {
      return truncate(JSON.stringify(value), 500);
    } catch (e) {
      return String(value);
    }
  }

  function report(error, options) {
    options = options || {};
    if (!config.enabled || !config.key || !config.endpoint) return false;
    if (sent >= MAX_REPORTS_PER_PAGE) return false;

    error = errorFrom(error);
    var stack = truncate(error.stack || "", 20000);
    if (/(chrome|moz|safari(-web)?)-extension:\/\//.test(stack) && !/https?:\/\//.test(stack)) return false;

    var signature = (error.name || "") + "|" + error.message + "|" + stack.split("\n")[1];
    if (seen[signature]) return false; // the same error once per page
    seen[signature] = true;
    sent += 1;

    var extra = options.context || {};
    var mergedContext = {};
    Object.keys(context).forEach(function (key) { mergedContext[key] = context[key]; });
    Object.keys(extra).forEach(function (key) { mergedContext[key] = extra[key]; });

    var body = {
      name: truncate(error.name || "Error", 200),
      message: truncate(error.message, 4000),
      stack: stack,
      type: options.type || "manual",
      handled: options.handled !== false && options.type !== "error" && options.type !== "unhandledrejection",
      occurred_at: now(),
      url: cleanUrl(location.href),
      referrer: document.referrer ? cleanUrl(document.referrer) : null,
      environment: config.environment,
      version: config.version,
      user: user.id ? { id: user.id } : null,
      context: mergedContext,
      breadcrumbs: breadcrumbs.slice(),
      language: navigator.language,
      viewport: window.innerWidth + "x" + window.innerHeight,
      notifier: { name: "watch.js", version: VERSION }
    };
    send(body);
    addBreadcrumb("log", (body.name + ": " + body.message), { reported: true });
    return true;
  }

  // text/plain keeps it a "simple" request: no CORS preflight. sendBeacon also survives page unloads.
  function send(body) {
    sendTo(config.endpoint, body);
  }

  function sendTo(endpoint, body) {
    var url = endpoint + (endpoint.indexOf("?") === -1 ? "?" : "&") + "key=" + encodeURIComponent(config.key);
    var json;
    try {
      json = JSON.stringify(body);
    } catch (e) {
      body.context = {};
      json = JSON.stringify(body);
    }
    try {
      if (navigator.sendBeacon && navigator.sendBeacon(url, new Blob([json], { type: "text/plain" }))) return;
    } catch (e) { /* fall through to fetch */ }
    try {
      originalFetch(url, { method: "POST", body: json, keepalive: true, mode: "cors", credentials: "omit",
                           headers: { "Content-Type": "text/plain" } }).catch(function () {});
    } catch (e) { /* never break the page */ }
  }

  // Uncaught errors (not failed <img>/<script> loads, which have no error object).
  window.addEventListener("error", function (event) {
    if (!event.error && !event.message) return;
    if (event.message === "Script error." && !event.error) return; // other site's script: no details
    report(event.error || { name: "Error", message: event.message,
                            stack: "    at " + (event.filename || "<anonymous>") + ":" + (event.lineno || 0) + ":" + (event.colno || 0) },
           { type: "error", handled: false });
  });

  window.addEventListener("unhandledrejection", function (event) {
    report(event.reason, { type: "unhandledrejection", handled: false });
  });

  // Breadcrumbs: clicks, page changes, console errors and warnings, failed requests.
  document.addEventListener("click", function (event) {
    var target = event.target && event.target.closest ? event.target.closest("a, button, input, select, [role=button], [data-action]") : null;
    if (target) addBreadcrumb("click", describe(target));
  }, true);

  var lastPath = location.pathname + location.search;
  function navigated() {
    var path = location.pathname + location.search;
    if (path !== lastPath) {
      addBreadcrumb("navigation", cleanUrl(path), { from: cleanUrl(lastPath) });
      lastPath = path;
    }
  }
  window.addEventListener("popstate", navigated);
  window.addEventListener("hashchange", navigated);
  document.addEventListener("turbo:load", navigated);

  ["error", "warn"].forEach(function (level) {
    var original = console[level];
    if (typeof original !== "function") return;
    console[level] = function () {
      try {
        var parts = Array.prototype.slice.call(arguments).map(function (part) {
          return part instanceof Error ? part.name + ": " + part.message : (typeof part === "string" ? part : safeJson(part));
        });
        addBreadcrumb("console", parts.join(" "), { level: level });
      } catch (e) { /* ignore */ }
      return original.apply(this, arguments);
    };
  });

  var originalFetch = window.fetch ? window.fetch.bind(window) : null;
  if (originalFetch) {
    window.fetch = function (input, init) {
      var method = ((init && init.method) || (input && input.method) || "GET").toUpperCase();
      var url = typeof input === "string" ? input : (input && input.url) || String(input);
      return originalFetch(input, init).then(function (response) {
        if (response.status >= 400) addBreadcrumb("http", method + " " + cleanUrl(url) + " → " + response.status);
        return response;
      }, function (error) {
        if (url.indexOf(config.endpoint) !== 0) addBreadcrumb("http", method + " " + cleanUrl(url) + " failed", { error: String(error) });
        throw error;
      });
    };
  }

  if (window.XMLHttpRequest) {
    var open = XMLHttpRequest.prototype.open;
    var sendXhr = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function (method, url) {
      this.__watch = { method: String(method).toUpperCase(), url: String(url) };
      return open.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function () {
      var request = this;
      if (request.__watch) {
        request.addEventListener("loadend", function () {
          if (request.status === 0 || request.status >= 400) {
            addBreadcrumb("http", request.__watch.method + " " + cleanUrl(request.__watch.url) + " → " + (request.status || "failed"));
          }
        });
      }
      return sendXhr.apply(this, arguments);
    };
  }

  // Page speed of real visits: Core Web Vitals (LCP, INP, CLS) plus FCP, TTFB and page load,
  // measured on full page loads and sent once when the page is hidden or left.
  var vitals = {};
  var vitalsSent = false;

  function observe(type, callback, options) {
    try {
      var observer = new PerformanceObserver(function (list) { list.getEntries().forEach(callback); });
      var settings = { type: type, buffered: true };
      Object.keys(options || {}).forEach(function (key) { settings[key] = options[key]; });
      observer.observe(settings);
    } catch (e) { /* this browser doesn't support it */ }
  }

  // /invoices/42/edit -> /invoices/:id/edit (pages group together, no ids or tokens leave the browser)
  function pagePath(path) {
    return String(path || "/").split("/").map(function (part) {
      if (/^\d+$/.test(part) || /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(part) ||
          /^[0-9a-f]{16,}$/i.test(part) || (part.length > 24 && /\d/.test(part))) return ":id";
      return part;
    }).join("/").slice(0, 200) || "/";
  }

  function deviceType() {
    try {
      if (/Mobi|Android|iPhone|iPad/i.test(navigator.userAgent) || window.matchMedia("(max-width: 767px)").matches) return "mobile";
    } catch (e) { /* ignore */ }
    return "desktop";
  }

  function vitalsEndpoint() {
    return config.vitalsEndpoint || config.endpoint.replace(/browser_errors(\?|$)/, "browser_vitals$1");
  }

  function flushVitals() {
    if (vitalsSent) return;
    try {
      var navigation = performance.getEntriesByType && performance.getEntriesByType("navigation")[0];
      if (navigation) {
        if (navigation.responseStart > 0) vitals.ttfb = navigation.responseStart;
        if (navigation.loadEventEnd > 0) vitals.load = navigation.loadEventEnd;
      }
    } catch (e) { /* ignore */ }
    if (vitals.lcp == null && vitals.fcp == null && vitals.ttfb == null) return;
    vitalsSent = true;
    var metrics = {};
    Object.keys(vitals).forEach(function (key) {
      metrics[key] = key === "cls" ? Math.round(vitals[key] * 10000) / 10000 : Math.round(vitals[key]);
    });
    sendTo(vitalsEndpoint(), {
      page: pagePath(location.pathname), metrics: metrics, device: deviceType(),
      connection: navigator.connection && navigator.connection.effectiveType || null,
      environment: config.environment, version: config.version
    });
  }

  function startVitals() {
    if (!config.vitals || !config.key || !config.endpoint || !window.PerformanceObserver) return;
    if (!(Math.random() < (isNaN(config.vitalsSample) ? 1 : config.vitalsSample))) return;
    observe("paint", function (entry) { if (entry.name === "first-contentful-paint") vitals.fcp = entry.startTime; });
    observe("largest-contentful-paint", function (entry) { vitals.lcp = entry.startTime; });
    var session = 0, first = 0, last = 0;
    observe("layout-shift", function (entry) {
      if (entry.hadRecentInput) return;
      if (session && entry.startTime - last < 1000 && entry.startTime - first < 5000) {
        session += entry.value;
      } else {
        session = entry.value;
        first = entry.startTime;
      }
      last = entry.startTime;
      vitals.cls = Math.max(vitals.cls || 0, session);
    });
    // Interaction to Next Paint, approximated by the slowest interaction on the page.
    observe("event", function (entry) {
      if (entry.interactionId && (vitals.inp == null || entry.duration > vitals.inp)) vitals.inp = entry.duration;
    }, { durationThreshold: 16 });
    observe("first-input", function (entry) {
      if (vitals.inp == null || entry.duration > vitals.inp) vitals.inp = entry.duration;
    });
    document.addEventListener("visibilitychange", function () {
      if (document.visibilityState === "hidden") flushVitals();
    });
    window.addEventListener("pagehide", flushVitals);
  }

  startVitals();

  window.WatchClient = {
    version: VERSION,
    notify: function (error, options) {
      return report(error, { type: "manual", handled: true, context: options && options.context });
    },
    setUser: function (value) {
      user = value && value.id != null ? { id: String(value.id) } : {};
    },
    setContext: function (value) {
      context = value && typeof value === "object" ? value : {};
    },
    addBreadcrumb: function (message, metadata) {
      addBreadcrumb("custom", message, metadata);
    },
    configure: function (options) {
      Object.keys(options || {}).forEach(function (key) {
        if (key === "userId") user = options.userId != null ? { id: String(options.userId) } : {};
        else config[key] = options[key];
      });
    }
  };
})();
