.pragma library

var API = "https://wallhaven.cc/api/v1/search"

function screenOrientation(screen) {
  if (!screen) return "landscape"
  return screen.height > screen.width ? "portrait" : "landscape"
}

function physicalSize(screen) {
  if (!screen) return { w: 1920, h: 1080 }
  var dpr = screen.devicePixelRatio || 1
  return { w: Math.round(screen.width * dpr), h: Math.round(screen.height * dpr) }
}

// orientation: "landscape" | "portrait" | "any"
function searchUrl(opts) {
  var p = [
    "purity=100",
    "categories=" + encodeURIComponent(opts.categories || "100"),
    "sorting=" + encodeURIComponent(opts.sorting || "toplist"),
    "page=" + (opts.page || 1)
  ]
  if (opts.sorting === "toplist") p.push("topRange=" + encodeURIComponent(opts.topRange || "1M"))
  if (opts.sorting === "random" && opts.seed) p.push("seed=" + encodeURIComponent(opts.seed))
  if (opts.orientation === "landscape" || opts.orientation === "portrait") p.push("ratios=" + opts.orientation)
  if (opts.atleast) p.push("atleast=" + opts.atleast)
  if (opts.query) p.push("q=" + encodeURIComponent(opts.query))
  return API + "?" + p.join("&")
}

function mapWallhaven(w) {
  var x = Number(w.dimension_x) || 0
  var y = Number(w.dimension_y) || 0
  return {
    id: String(w.id),
    remote: true,
    thumb: (w.thumbs && (w.thumbs.original || w.thumbs.large)) || "",
    full: String(w.path || ""),
    page: String(w.url || ""),
    width: x,
    height: y,
    orientation: y > x ? "portrait" : "landscape",
    path: ""
  }
}

function fileNameFor(item) {
  var ext = (item.full.match(/\.([a-z0-9]+)$/i) || [null, "jpg"])[1]
  return "wallhaven-" + item.id + "." + ext
}

function idFromPath(path) {
  var m = String(path).match(/wallhaven-([a-z0-9]+)\.[a-z0-9]+$/i)
  return m ? m[1] : ""
}

// "W H<TAB>/path" lines from `magick identify` -> items, newest first
function parseLocal(text) {
  var out = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var tab = lines[i].indexOf("\t")
    if (tab < 0) continue
    var dims = lines[i].slice(0, tab).split(" ")
    var path = lines[i].slice(tab + 1)
    if (!path) continue
    var w = parseInt(dims[0], 10) || 0
    var h = parseInt(dims[1], 10) || 0
    out.push({
      id: idFromPath(path) || path,
      remote: false,
      thumb: "file://" + path,
      full: "",
      page: "",
      width: w,
      height: h,
      orientation: h > w ? "portrait" : "landscape",
      path: path
    })
  }
  return out
}

function matchesOrientation(item, orientation) {
  return orientation === "any" || item.orientation === orientation
}

function expandHome(path, home) {
  path = String(path || "")
  return path.indexOf("~/") === 0 ? home + path.slice(1) : path
}

function intervalLabel(minutes) {
  if (minutes >= 1440) return "day"
  if (minutes >= 60) return (minutes / 60) + "h"
  return minutes + "m"
}
