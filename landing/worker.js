// Send www and http to https://sillog.app so search engines see one copy of each page.
// Pages come in Korean (/, /privacy) and English (/en/, /en/privacy). Korea gets Korean and everywhere else English,
// unless the visitor picked one with ?lang= (kept in a cookie). Crawlers are never moved, so both copies get indexed.
const EN = { "/": "/en/", "/privacy": "/en/privacy" };
const KO = Object.fromEntries(Object.entries(EN).map(([ko, en]) => [en, ko]));
const BOT = /bot|crawl|spider|slurp|facebookexternalhit|scrap|preview/i;

const go = (to, extra = {}) => new Response(null, { status: 302, headers: { Location: to, "Cache-Control": "no-store", ...extra } });

export default {
  fetch(request, env) {
    const url = new URL(request.url);
    if (url.hostname === "www.sillog.app" || url.protocol === "http:") {
      url.hostname = "sillog.app";
      url.protocol = "https:";
      return Response.redirect(url.toString(), 301);
    }
    const pick = url.searchParams.get("lang");
    if (pick === "ko" || pick === "en") {                       // the language links: remember the choice for a year
      url.searchParams.delete("lang");
      const path = pick === "en" ? EN[url.pathname] ?? url.pathname : KO[url.pathname] ?? url.pathname;
      return go(path + url.search, { "Set-Cookie": `lang=${pick}; Path=/; Max-Age=31536000; SameSite=Lax; Secure` });
    }
    if (EN[url.pathname]) {                                     // a Korean page: move non-Korean visitors to its English copy
      const saved = /(?:^|;\s*)lang=(ko|en)\b/.exec(request.headers.get("Cookie") || "")?.[1];
      const bot = BOT.test(request.headers.get("User-Agent") || "");
      const lang = saved || (bot || request.cf?.country === "KR" ? "ko" : "en");
      if (lang === "en") return go(EN[url.pathname] + url.search, { Vary: "Cookie" });
    }
    return env.ASSETS.fetch(request);
  },
};
