(function () {
  "use strict";

  var REPO = "ssut/Sukurini";
  var RELEASES_URL = "https://github.com/" + REPO + "/releases";
  var DESIGN_WIDTH = 900;

  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)");
  var systemLight = window.matchMedia("(prefers-color-scheme: light)");

  function formatSize(bytes) {
    return (bytes / 1048576).toFixed(1) + " MB";
  }

  /* Setting textContent replaces the text node, which throws away the cached
     English original the language pass matches on. So the button is re-rendered
     from state on every language change rather than translated in place. */
  var releaseState = null;

  function paintDownload() {
    var label = document.getElementById("download-label");
    var meta = document.getElementById("release-meta");
    if (!label) return;
    if (!releaseState) {
      label.textContent = t("hero.download");
    } else if (releaseState.kind === "fallback") {
      label.textContent = t("hero.download.fallback");
    } else {
      label.textContent = t("hero.download.versioned", { version: releaseState.version });
      if (meta && releaseState.meta) meta.textContent = releaseState.meta;
    }
  }

  function fallback(reason) {
    document.getElementById("download").href = RELEASES_URL;
    releaseState = { kind: "fallback" };
    paintDownload();
    console.info("release status=fallback reason=" + reason);
  }

  function applyRelease(data) {
    var version = String(data.tag_name || "").replace(/^v/, "");
    if (!version) {
      fallback("tag_missing");
      return;
    }
    var assets = Array.isArray(data.assets) ? data.assets : [];
    var asset = assets.filter(function (item) { return /\.zip$/i.test(item.name || ""); })[0];
    if (asset && asset.browser_download_url) {
      document.getElementById("download").href = asset.browser_download_url;
      releaseState = {
        kind: "version",
        version: version,
        meta: version + " · " + formatSize(asset.size) + " · Apache-2.0"
      };
      console.info("release status=resolved version=" + version + " asset=" + asset.name);
    } else {
      document.getElementById("download").href = data.html_url || RELEASES_URL;
      releaseState = { kind: "version", version: version, meta: version + " · Apache-2.0" };
      console.info("release status=resolved_without_asset version=" + version);
    }
    paintDownload();
  }

  function loadRelease() {
    if (!("fetch" in window)) {
      fallback("fetch_unsupported");
      return;
    }
    fetch("https://api.github.com/repos/" + REPO + "/releases/latest", {
      headers: { Accept: "application/vnd.github+json" }
    })
      .then(function (response) {
        if (!response.ok) {
          fallback(response.status === 404 ? "no_release_published" : "http_" + response.status);
          return null;
        }
        return response.json();
      })
      .then(function (data) { if (data) applyRelease(data); })
      .catch(function () { fallback("network_error"); });
  }

  var TABLE = window.SUKURINI_I18N || {};
  var LANGS = ["en", "ko", "ja"];
  var byEnglish = {};

  function norm(value) {
    return String(value).replace(/\s+/g, " ").trim();
  }

  Object.keys(TABLE).forEach(function (key) {
    var en = norm(TABLE[key].en);
    if (en && !byEnglish[en]) byEnglish[en] = TABLE[key];
  });

  var lang = "en";

  function t(key, vars) {
    var entry = TABLE[key];
    var text = entry ? (entry[lang] || entry.en) : key;
    if (!vars) return text;
    return text.replace(/\{(\w+)\}/g, function (whole, name) {
      return name in vars ? vars[name] : whole;
    });
  }

  function textNodes(root) {
    var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
    var found = [];
    var node;
    while ((node = walker.nextNode())) found.push(node);
    return found;
  }

  var ATTR_KEYS = [
    [".skip", "textContent", "a11y.skip"],
    ['[data-scene="capture"]', "aria-label", "a11y.scene.capture"],
    ['[data-scene="browse"]', "aria-label", "a11y.scene.browse"],
    ['[data-scene="storage"]', "aria-label", "a11y.scene.storage"],
    ['.car-arrow[data-dir="-1"]', "aria-label", "a11y.carousel.prev"],
    ['.car-arrow[data-dir="1"]', "aria-label", "a11y.carousel.next"],
    [".tabs", "aria-label", "a11y.tablist"],
    [".ghstar", "aria-label", "a11y.ghstar"]
  ];

  function escapeHtml(value) {
    return String(value)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }

  /* Two paragraphs carry inline markup, so they are rebuilt from the string
     with their one meaningful tag re-applied around a token. */
  var RICH_KEYS = [
    [".origin p", "origin.body", "Screenie",
     '<a href="https://apps.apple.com/app/screenie/id1195678496">Screenie</a>'],
    /* Japanese has no word spacing, so the product name runs straight into the
       sentence. A quiet underline gives it an edge. */
    [".intro p", "hero.body", { ja: "スクリーニー" }, '<span class="brandmark">$1</span>'],
    ["#panel h2", "panel.h2", null, null]
  ];

  function paintLanguage() {
    document.documentElement.setAttribute("lang", lang);
    document.title = t("meta.title");

    textNodes(document.body).forEach(function (node) {
      var original = node.i18nOriginal;
      if (original === undefined) {
        original = node.nodeValue;
        if (!byEnglish[norm(original)]) return;
        node.i18nOriginal = original;
      }
      var entry = byEnglish[norm(original)];
      if (!entry) return;
      node.nodeValue = original.match(/^\s*/)[0] +
                       (entry[lang] || entry.en) +
                       original.match(/\s*$/)[0];
    });

    ATTR_KEYS.forEach(function (rule) {
      var el = document.querySelector(rule[0]);
      if (!el) return;
      if (rule[1] === "textContent") el.textContent = t(rule[2]);
      else el.setAttribute(rule[1], t(rule[2]));
    });

    RICH_KEYS.forEach(function (rule) {
      var el = document.querySelector(rule[0]);
      if (!el) return;
      var token = rule[2] && (typeof rule[2] === "string" ? rule[2] : rule[2][lang]);
      var text = escapeHtml(t(rule[1])).replace(/\n/g, "<br>");
      el.innerHTML = token ? text.replace(token, rule[3].replace("$1", token)) : text;
    });

    var description = document.querySelector('meta[name="description"]');
    if (description) description.setAttribute("content", t("meta.description"));

    labelTheme();
    paintDownload();
  }

  function setLanguage(next, persist) {
    if (LANGS.indexOf(next) === -1) next = "en";
    lang = next;
    paintLanguage();
    Array.prototype.slice.call(document.querySelectorAll(".lang button")).forEach(function (button) {
      button.setAttribute("aria-pressed", String(button.getAttribute("data-lang") === lang));
    });
    if (persist) {
      try { localStorage.setItem("sukurini-lang", lang); } catch (error) { void error; }
      var url = new URL(window.location.href);
      if (lang === "en") url.searchParams.delete("lang");
      else url.searchParams.set("lang", lang);
      history.replaceState(null, "", url);
    }
    console.info("i18n status=applied lang=" + lang);
    document.dispatchEvent(new CustomEvent("sukurini:lang"));
  }

  function initialLanguage() {
    var fromUrl = new URL(window.location.href).searchParams.get("lang");
    if (LANGS.indexOf(fromUrl) !== -1) return fromUrl;
    var stored = null;
    try { stored = localStorage.getItem("sukurini-lang"); } catch (error) { void error; }
    if (LANGS.indexOf(stored) !== -1) return stored;
    var preferred = (navigator.languages || [navigator.language || ""]).join(",").toLowerCase();
    if (preferred.indexOf("ko") === 0 || preferred.indexOf(",ko") !== -1) return "ko";
    if (preferred.indexOf("ja") === 0 || preferred.indexOf(",ja") !== -1) return "ja";
    return "en";
  }

  var themeButton = document.getElementById("theme");

  function effectiveTheme() {
    var forced = document.documentElement.getAttribute("data-theme");
    if (forced) return forced;
    return systemLight.matches ? "light" : "dark";
  }

  function labelTheme() {
    if (!themeButton) return;
    var next = effectiveTheme() === "dark" ? "light" : "dark";
    themeButton.setAttribute("aria-label", "Switch to " + next + " appearance");
  }

  function applyTheme(value, persist) {
    if (value) document.documentElement.setAttribute("data-theme", value);
    else document.documentElement.removeAttribute("data-theme");
    if (persist) {
      try { localStorage.setItem("sukurini-theme", value || ""); } catch (error) { void error; }
    }
    labelTheme();
    console.info("theme status=applied value=" + (value || "system"));
  }

  if (themeButton) {
    var storedTheme = null;
    try { storedTheme = localStorage.getItem("sukurini-theme"); } catch (error) { void error; }
    if (storedTheme === "light" || storedTheme === "dark") applyTheme(storedTheme, false);
    else labelTheme();

    themeButton.addEventListener("click", function () {
      applyTheme(effectiveTheme() === "dark" ? "light" : "dark", true);
    });
    systemLight.addEventListener("change", labelTheme);
  }

  function createScene(root, build) {
    var desk = root.querySelector(".scene-desk");
    var cursor = root.querySelector(".cursor");
    var caption = root.querySelector(".caption");
    var button = root.querySelector(".replay-layer button");
    var name = root.getAttribute("data-scene");
    var timers = [];
    var playing = false;

    function q(selector) { return root.querySelector(selector); }
    function all(selector) { return Array.prototype.slice.call(root.querySelectorAll(selector)); }
    function at(ms, fn) { timers.push(setTimeout(fn, ms)); }
    function stop() { timers.forEach(clearTimeout); timers = []; }

    function scale() {
      var width = root.getBoundingClientRect().width;
      return width ? width / DESIGN_WIDTH : 1;
    }

    function boxOf(target) {
      var el = typeof target === "string" ? q(target) : target;
      var z = scale();
      var origin = desk.getBoundingClientRect();
      var box = el.getBoundingClientRect();
      return {
        x: (box.left - origin.left) / z,
        y: (box.top - origin.top) / z,
        w: box.width / z,
        h: box.height / z
      };
    }

    function centerOf(target) {
      var box = boxOf(target);
      return { x: box.x + box.w / 2, y: box.y + box.h / 2 };
    }

    function place(x, y) {
      cursor.style.transition = "none";
      cursor.style.transform = "translate(" + x + "px," + y + "px)";
      cursor.offsetHeight;
      cursor.style.transition = "opacity 0.2s ease";
    }

    function move(x, y, ms, ease) {
      cursor.style.transition =
        "transform " + ms + "ms " + (ease || "cubic-bezier(0.42,0,0.24,1)") + ", opacity 0.2s ease";
      cursor.style.transform = "translate(" + x + "px," + y + "px)";
    }

    function moveTo(target, ms, ease) {
      var point = centerOf(target);
      move(point.x, point.y, ms, ease);
    }

    function step(text) {
      caption.textContent = text;
      caption.classList.add("on");
    }

    function finish(reason) {
      playing = false;
      caption.classList.remove("on");
      root.classList.add("done");
      console.info("scene=" + name + " status=finished reason=" + reason);
    }

    var api = {
      cursor: cursor, q: q, all: all, at: at, place: place, move: move,
      moveTo: moveTo, centerOf: centerOf, boxOf: boxOf, step: step, finish: finish
    };

    function play() {
      if (playing) return;
      playing = true;
      stop();
      root.classList.remove("done");
      caption.classList.remove("on");
      console.info("scene=" + name + " status=playing reduced=" + reduced.matches);
      build(api, reduced.matches ? "reduced" : "play");
    }

    build(api, "reset");
    button.addEventListener("click", play);
    document.addEventListener("sukurini:lang", function () {
      if (playing) return;
      build(api, "reset");
      root.classList.remove("done");
    });

    if ("IntersectionObserver" in window) {
      /* Replay every time the section is scrolled back into view, but only on
         the edge — not on every scroll tick while it is already on screen. */
      var inView = false;
      new IntersectionObserver(function (entries) {
        entries.forEach(function (entry) {
          if (entry.isIntersecting && !inView) {
            inView = true;
            play();
          } else if (!entry.isIntersecting) {
            inView = false;
          }
        });
      }, { threshold: 0.25 }).observe(root);
    } else {
      play();
    }
  }

  function buildCapture(s, mode) {
    var cursor = s.cursor;
    var sel = s.q(".sel");
    var selSize = s.q(".sel-size");
    var flash = s.q(".flash");
    var indicator = s.q(".sk-icon");
    var drop = s.q(".win-drop");
    var attach = s.q(".attach");
    var payload = s.q(".payload");

    cursor.classList.remove("on", "press", "sizing");
    cursor.setAttribute("data-mode", "cross");
    s.place(70, 96);
    sel.classList.remove("on");
    sel.style.transition = "none";
    sel.style.width = "0px";
    sel.style.height = "0px";
    payload.classList.remove("lift", "drop");
    attach.classList.remove("shown");
    drop.classList.remove("over");
    indicator.classList.remove("pending", "pulsing");
    flash.classList.remove("fire");

    if (mode === "reset") return;

    if (mode === "reduced") {
      attach.classList.add("shown");
      s.finish("reduced_motion");
      return;
    }

    var card = s.boxOf(".card");
    var region = { x: card.x - 6, y: card.y - 6, w: card.w + 12, h: card.h + 12 };
    sel.style.left = region.x + "px";
    sel.style.top = region.y + "px";

    s.at(400, function () {
      cursor.classList.add("on");
      s.step(t("capture.caption.1"));
    });

    s.at(700, function () { s.move(region.x, region.y, 700); });

    s.at(1500, function () {
      sel.classList.add("on");
      cursor.classList.add("sizing");
      sel.style.transition = "width 1600ms cubic-bezier(0.42,0,0.24,1), height 1600ms cubic-bezier(0.42,0,0.24,1)";
      sel.style.width = region.w + "px";
      sel.style.height = region.h + "px";
      selSize.textContent = Math.round(region.w) + " × " + Math.round(region.h);
      s.move(region.x + region.w, region.y + region.h, 1600);
    });

    s.at(3200, function () {
      sel.classList.remove("on");
      cursor.classList.remove("sizing");
      flash.classList.add("fire");
      s.step(t("capture.caption.2"));
    });

    s.at(3450, function () {
      flash.classList.remove("fire");
      indicator.classList.add("pending", "pulsing");
      s.step(t("capture.caption.3"));
    });

    s.at(3950, function () {
      cursor.setAttribute("data-mode", "arrow");
      s.moveTo(".sk-icon", 1700);
    });

    s.at(5700, function () { s.step(t("capture.caption.4")); });

    s.at(6700, function () {
      cursor.classList.add("press");
      payload.classList.add("lift");
      s.step(t("capture.caption.5"));
    });

    s.at(7100, function () { s.moveTo(".win-drop", 1900); });

    s.at(8200, function () { drop.classList.add("over"); });

    s.at(9100, function () {
      cursor.classList.remove("press");
      payload.classList.add("drop");
      drop.classList.remove("over");
      attach.classList.add("shown");
      indicator.classList.remove("pending", "pulsing");
      s.step(t("capture.caption.6"));
    });

    s.at(9700, function () {
      var here = s.centerOf(".win-drop");
      s.move(here.x + 96, here.y + 78, 900);
      cursor.classList.remove("on");
    });

    s.at(10700, function () { s.finish("complete"); });
  }

  function buildBrowse(s, mode) {
    var cursor = s.cursor;
    var shelf = s.q(".shelf");
    var tiles = s.all(".mini-tile");
    var drop = s.q(".win-drop");
    var attaches = s.all(".attach");
    var payload = s.q(".payload");
    var picks = [tiles[2], tiles[1], tiles[5]];

    cursor.classList.remove("on", "press", "mod");
    cursor.setAttribute("data-mode", "arrow");
    s.place(330, 300);
    shelf.classList.remove("open");
    tiles.forEach(function (tile) { tile.classList.remove("picked"); });
    attaches.forEach(function (item) { item.classList.remove("shown"); });
    drop.classList.remove("over");
    payload.classList.remove("lift", "drop");

    if (mode === "reset") return;

    if (mode === "reduced") {
      shelf.classList.add("open");
      picks.forEach(function (tile) { tile.classList.add("picked"); });
      attaches.forEach(function (item) { item.classList.add("shown"); });
      s.finish("reduced_motion");
      return;
    }

    s.at(400, function () {
      cursor.classList.add("on");
      s.step(t("browse.caption.1"));
    });

    s.at(750, function () { s.moveTo(".sk-icon", 1500); });

    s.at(2350, function () { cursor.classList.add("press"); });

    s.at(2520, function () {
      cursor.classList.remove("press");
      shelf.classList.add("open");
      s.step(t("browse.caption.2"));
    });

    s.at(3300, function () { s.moveTo(picks[0], 950); });

    s.at(4300, function () {
      cursor.classList.add("press");
      picks[0].classList.add("picked");
      s.step(t("browse.caption.3"));
    });
    s.at(4470, function () { cursor.classList.remove("press"); });

    s.at(4850, function () {
      cursor.classList.add("mod");
      s.step(t("browse.caption.4"));
      s.moveTo(picks[1], 900);
    });

    s.at(5800, function () {
      cursor.classList.add("press");
      picks[1].classList.add("picked");
    });
    s.at(5970, function () { cursor.classList.remove("press"); });

    s.at(6350, function () { s.moveTo(picks[2], 900); });

    s.at(7300, function () {
      cursor.classList.add("press");
      picks[2].classList.add("picked");
    });
    s.at(7470, function () { cursor.classList.remove("press"); });

    s.at(8000, function () {
      cursor.classList.remove("mod");
      cursor.classList.add("press");
      payload.classList.add("lift");
      s.step(t("browse.caption.5"));
    });

    s.at(8450, function () { s.moveTo(".win-drop", 1900); });

    s.at(9600, function () { drop.classList.add("over"); });

    s.at(10450, function () {
      cursor.classList.remove("press");
      payload.classList.add("drop");
      drop.classList.remove("over");
      shelf.classList.remove("open");
      s.step(t("browse.caption.6"));
      attaches.forEach(function (item, index) {
        s.at(index * 110, function () { item.classList.add("shown"); });
      });
    });

    s.at(11200, function () {
      var here = s.centerOf(".win-drop");
      s.move(here.x + 90, here.y + 92, 900);
      cursor.classList.remove("on");
    });

    s.at(12100, function () { s.finish("complete"); });
  }


  function toKb(text) {
    var parts = String(text).split(" ");
    var value = parseFloat(parts[0]);
    if (parts[1] === "GB") return value * 1024 * 1024;
    return parts[1] === "MB" ? value * 1024 : value;
  }

  function formatDisk(kb) {
    if (kb >= 1024 * 1024) return (kb / 1024 / 1024).toFixed(2) + " GB";
    return Math.round(kb / 1024) + " MB";
  }

  function buildStorage(s, mode) {
    var TOTAL_FILES = 428;
    var TOTAL_KB = 1.24 * 1024 * 1024;
    var RATIO = 0.283;
    var SAVED_KB = TOTAL_KB * (1 - RATIO);

    var rows = s.all(".frow");
    var strip = s.q(".finder-rows");
    var amount = s.q(".ob-amount b");
    var unit = s.q(".ob-amount span");
    var track = s.q(".ob-track i");
    var count = s.q(".ob-count");
    var pct = s.q(".ob-pct");
    var caption = s.q(".ob-caption");
    var total = s.q(".finder-total");
    var title = s.q(".ob-title");

    function paint(row, converted) {
      row.classList.toggle("done", converted);
      row.querySelector(".fname i").textContent = converted ? ".webp" : ".png";
      row.querySelector(".fkind").textContent = converted ? t("finder.kind.webp") : t("finder.kind.png");
      row.querySelector(".fsize").textContent = row.getAttribute(converted ? "data-after" : "data-before");
    }

    function progress(fraction) {
      var files = Math.round(TOTAL_FILES * fraction);
      var saved = SAVED_KB * fraction;
      var value = formatDisk(saved).split(" ");
      amount.textContent = value[0];
      unit.textContent = value[1];
      track.style.width = (fraction * 100) + "%";
      count.textContent = String(files);
      pct.textContent = Math.round((1 - RATIO) * 100 * (fraction > 0 ? 1 : 0)) + "%";
      caption.textContent = t("onboarding.caption.template", { done: files, total: TOTAL_FILES });
      total.textContent = formatDisk(TOTAL_KB - saved);
    }

    var maxScroll = Math.max(0, rows.length * 26 - 496);
    strip.style.transition = "none";
    strip.style.transform = "translateY(0)";
    rows.forEach(function (row) {
      row.classList.remove("flip");
      paint(row, false);
    });
    title.textContent = t("onboarding.title.running");
    progress(0);

    if (strip._raf) {
      cancelAnimationFrame(strip._raf);
      strip._raf = null;
    }

    if (mode === "reset") return;

    if (mode === "reduced") {
      rows.forEach(function (row) { paint(row, true); });
      progress(1);
      strip.style.transform = "translateY(-" + maxScroll + "px)";
      title.textContent = t("onboarding.title.done", { size: formatDisk(SAVED_KB) });
      s.finish("reduced_motion");
      return;
    }

    var SPAN = 5600;
    var LEAD_IN = 800;
    var BAND = 16;
    var edge = 0;
    var faded = 0;
    var startedAt = null;
    var completed = false;

    s.at(250, function () { s.step(t("storage.caption.1")); });
    s.at(660, function () { s.step(t("storage.caption.2")); });

    function tick(now) {
      if (startedAt === null) startedAt = now;
      var fraction = Math.min(1, (now - startedAt) / SPAN);

      var target = Math.round(fraction * rows.length);
      while (edge < target) {
        paint(rows[edge], true);
        rows[edge].classList.add("flip");
        edge += 1;
      }
      while (faded < edge - BAND) {
        rows[faded].classList.remove("flip");
        faded += 1;
      }

      strip.style.transform = "translateY(-" + (fraction * maxScroll).toFixed(1) + "px)";
      progress(fraction);

      if (fraction < 1) {
        strip._raf = requestAnimationFrame(tick);
        return;
      }
      complete();
    }

    function complete() {
      if (completed) return;
      completed = true;
      if (strip._raf) {
        cancelAnimationFrame(strip._raf);
        strip._raf = null;
      }
      rows.forEach(function (row) {
        row.classList.remove("flip");
        paint(row, true);
      });
      progress(1);
      strip.style.transform = "translateY(-" + maxScroll + "px)";
      title.textContent = t("onboarding.title.done", { size: formatDisk(SAVED_KB) });
      s.step(t("storage.caption.3"));
      s.at(900, function () { s.finish("complete"); });
    }

    s.at(LEAD_IN, function () { strip._raf = requestAnimationFrame(tick); });
    s.at(LEAD_IN + SPAN + 500, complete);
  }

  var builders = { capture: buildCapture, browse: buildBrowse, storage: buildStorage };

  Array.prototype.slice.call(document.querySelectorAll(".scene")).forEach(function (root) {
    var build = builders[root.getAttribute("data-scene")];
    if (build) createScene(root, build);
  });

  var typed = document.getElementById("typed");
  var caret = document.getElementById("caret");
  var placeholder = document.getElementById("placeholder");
  var sort = document.getElementById("sort");
  var dayA = document.getElementById("day-a");
  var rowA = document.getElementById("row-a");
  var otherDays = [document.getElementById("day-b"), document.getElementById("day-c")];
  var otherRows = [document.getElementById("row-b"), document.getElementById("row-c")];
  var panelBody = document.querySelector(".panel-body");
  var tiles = Array.prototype.slice.call(document.querySelectorAll(".tile"));
  var tabs = Array.prototype.slice.call(document.querySelectorAll(".tabs button"));
  var arrows = Array.prototype.slice.call(document.querySelectorAll(".car-arrow"));
  var typeTimer = null;

  tiles.forEach(function (tile) { tile.home = tile.parentNode; });

  function swap(mutate) {
    if (reduced.matches) { mutate(); return; }
    panelBody.classList.add("swapping");
    setTimeout(function () {
      mutate();
      panelBody.classList.remove("swapping");
    }, 220);
  }

  function showBrowsing() {
    typed.textContent = "";
    placeholder.hidden = false;
    caret.hidden = true;
    sort.hidden = true;
    dayA.textContent = t("gallery.day.today");
    otherDays.forEach(function (day) { day.hidden = false; });
    otherRows.forEach(function (row) { row.hidden = false; });
    tiles.forEach(function (tile, index) {
      if (tile.parentNode !== tile.home) tile.home.appendChild(tile);
      tile.hidden = false;
      tile.classList.toggle("selected", index === 0);
    });
    panelBody.classList.remove("locked");
    panelBody.scrollTop = 0;
    console.info("gallery state=browsing tiles=" + tiles.length + " scrollable=true");
  }

  function showResults(query, hits) {
    var wanted = hits ? hits.split(",") : [];
    var matched = tiles.filter(function (tile) {
      return wanted.indexOf(tile.getAttribute("data-shot")) !== -1;
    });
    placeholder.hidden = true;
    caret.hidden = false;
    sort.hidden = false;
    dayA.textContent = t("gallery.day.bestMatches");
    otherDays.forEach(function (day) { day.hidden = true; });
    otherRows.forEach(function (row) { row.hidden = true; });
    tiles.forEach(function (tile) {
      tile.hidden = true;
      tile.classList.remove("selected");
    });
    matched.forEach(function (tile) {
      rowA.appendChild(tile);
      tile.hidden = false;
    });
    panelBody.classList.add("locked");
    panelBody.scrollTop = 0;
    console.info("gallery state=results query=" + query + " shown=" + matched.length);
  }

  function typeQuery(query, hits) {
    var index = 0;
    placeholder.hidden = true;
    caret.hidden = false;
    typed.textContent = "";
    clearInterval(typeTimer);
    typeTimer = setInterval(function () {
      index += 1;
      typed.textContent = query.slice(0, index);
      if (index < query.length) return;
      clearInterval(typeTimer);
      swap(function () { showResults(query, hits); });
    }, 55);
  }

  function selectTab(tab) {
    tabs.forEach(function (item) {
      item.setAttribute("aria-selected", String(item === tab));
    });
    var qkey = tab.getAttribute("data-qkey");
    var query = qkey ? t(qkey) : (tab.getAttribute("data-q") || "");
    clearInterval(typeTimer);
    if (!query) {
      swap(showBrowsing);
      return;
    }
    var hits = tab.getAttribute("data-hits");
    if (reduced.matches) {
      typed.textContent = query;
      showResults(query, hits);
      return;
    }
    typeQuery(query, hits);
  }

  function step(direction) {
    var current = tabs.filter(function (tab) {
      return tab.getAttribute("aria-selected") === "true";
    })[0];
    var index = tabs.indexOf(current);
    var next = (index + direction + tabs.length) % tabs.length;
    selectTab(tabs[next]);
  }

  var autoTimer = null;
  var autoStopped = false;

  function stopAuto() {
    autoStopped = true;
    clearInterval(autoTimer);
    autoTimer = null;
    if (carousel) carousel.classList.remove("running");
  }

  var CAROUSEL_INTERVAL = 5200;
  var carousel = document.querySelector(".carousel");

  function armProgress() {
    if (!carousel) return;
    var fill = carousel.querySelector(".car-progress i");
    carousel.classList.remove("running");
    void fill.offsetWidth;
    carousel.style.setProperty("--car-interval", CAROUSEL_INTERVAL + "ms");
    carousel.classList.add("running");
  }

  function startAuto() {
    if (autoStopped || autoTimer || reduced.matches) return;
    armProgress();
    autoTimer = setInterval(function () {
      step(1);
      armProgress();
    }, CAROUSEL_INTERVAL);
  }

  function pauseAuto() {
    clearInterval(autoTimer);
    autoTimer = null;
    if (carousel) carousel.classList.remove("running");
  }

  if (tabs.length) {
    tabs.forEach(function (tab) {
      tab.addEventListener("click", function () { stopAuto(); selectTab(tab); });
    });
    arrows.forEach(function (arrow) {
      arrow.addEventListener("click", function () {
        stopAuto();
        step(Number(arrow.getAttribute("data-dir")));
      });
    });

    var section = document.getElementById("panel");
    if (section && "IntersectionObserver" in window) {
      new IntersectionObserver(function (entries) {
        entries.forEach(function (entry) {
          if (entry.isIntersecting) startAuto();
          else pauseAuto();
        });
      }, { threshold: 0.4 }).observe(section);
    } else {
      startAuto();
    }

    showBrowsing();
    document.addEventListener("sukurini:lang", function () {
      var active = tabs.filter(function (tab) {
        return tab.getAttribute("aria-selected") === "true";
      })[0];
      clearInterval(typeTimer);
      var query = active && active.getAttribute("data-qkey");
      if (!query) { showBrowsing(); return; }
      typed.textContent = t(query);
      showResults(t(query), active.getAttribute("data-hits"));
    });
  }

  Array.prototype.slice.call(document.querySelectorAll(".lang button")).forEach(function (button) {
    button.addEventListener("click", function () {
      setLanguage(button.getAttribute("data-lang"), true);
    });
  });
  setLanguage(initialLanguage(), false);

  function loadStars() {
    if (!("fetch" in window)) return;
    fetch("https://api.github.com/repos/" + REPO, {
      headers: { Accept: "application/vnd.github+json" }
    })
      .then(function (response) { return response.ok ? response.json() : null; })
      .then(function (data) {
        if (!data || typeof data.stargazers_count !== "number") return;
        var count = data.stargazers_count;
        var label = count >= 1000 ? (count / 1000).toFixed(1).replace(/\.0$/, "") + "k" : String(count);
        var el = document.getElementById("ghstar-count");
        el.textContent = label;
        el.hidden = false;
        console.info("stars status=resolved count=" + count);
      })
      .catch(function () { console.info("stars status=unavailable"); });
  }

  loadStars();
  loadRelease();
})();
