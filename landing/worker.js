// Send www and http to https://sillog.app so search engines see one copy of each page.
export default {
  fetch(request, env) {
    const url = new URL(request.url);
    if (url.hostname === "www.sillog.app" || url.protocol === "http:") {
      url.hostname = "sillog.app";
      url.protocol = "https:";
      return Response.redirect(url.toString(), 301);
    }
    return env.ASSETS.fetch(request);
  },
};
