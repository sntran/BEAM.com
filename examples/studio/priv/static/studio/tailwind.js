// The Tailwind step of the app, in the browser of the page of the app. It
// compiles assets/css/app.css of the project with the compiler of
// Tailwind 4 and the plugins of phx.new (daisyUI and heroicons), puts the
// CSS in the page, and gives it to the studio, which serves it at
// /assets/css/app.css for the next load. The classes come from the text of
// the files that the @source lines of phx.new name.
const TW = "https://cdn.jsdelivr.net/npm/tailwindcss@4.3.3";
const DAISY = "https://cdn.jsdelivr.net/npm/daisyui@5.5.20";
const HEROICONS = "https://cdn.jsdelivr.net/npm/heroicons@2.2.0";
const ICON_SETS = [["-micro", "/16/solid"], ["-mini", "/20/solid"], ["-solid", "/24/solid"], ["", "/24/outline"]];

const text = (url) => fetch(url).then((r) => {
  if (!r.ok) throw new Error(`${url}: ${r.status}`);
  return r.text();
});

async function loadStylesheet(id, base) {
  if (id === "tailwindcss" || id.startsWith("tailwindcss/")) {
    const file = id === "tailwindcss" ? "index.css" : id.slice("tailwindcss/".length);
    const path = `${TW}/${file.endsWith(".css") ? file : `${file}.css`}`;
    return { path, base: TW, content: await text(path) };
  }
  if (id.startsWith("phoenix-colocated/")) return { path: id, base, content: "" };
  if (/^https?:/.test(base) && id.startsWith(".")) {
    const path = new URL(id, `${base}/`).href;
    return { path, base: path.replace(/\/[^/]*$/, ""), content: await text(path) };
  }
  if (!id.startsWith(".") && !id.startsWith("/")) {
    const path = `https://cdn.jsdelivr.net/npm/${id}`;
    return { path, base: path.replace(/\/[^/]*$/, ""), content: await text(path) };
  }
  console.warn(`studio: no stylesheet for @import "${id}"`);
  return { path: id, base, content: "" };
}

// The plugin of phx.new (assets/vendor/heroicons.js) reads the files of
// the heroicons package. This one takes the icons of the page from npm.
async function heroicons(candidates) {
  const icons = new Map();
  await Promise.all(candidates.filter((c) => /^hero-[a-z0-9-]+$/.test(c)).map(async (c) => {
    const name = c.slice(5);
    const [suffix, dir] = ICON_SETS.find(([s]) => s === "" || name.endsWith(s));
    const file = suffix ? name.slice(0, -suffix.length) : name;
    try {
      icons.set(name, await text(`${HEROICONS}${dir}/${file}.svg`));
    } catch { /* not an icon */ }
  }));
  return {
    handler({ matchComponents, theme }) {
      const values = {};
      for (const [name, svg] of icons) values[name] = { name, svg };
      matchComponents({
        hero: ({ name, svg }) => {
          const content = encodeURIComponent(svg.replace(/\r?\n|\r/g, ""));
          let size = theme("spacing.6");
          if (name.endsWith("-mini")) size = theme("spacing.5");
          else if (name.endsWith("-micro")) size = theme("spacing.4");
          return {
            [`--hero-${name}`]: `url('data:image/svg+xml;utf8,${content}')`,
            "-webkit-mask": `var(--hero-${name})`,
            mask: `var(--hero-${name})`,
            "mask-repeat": "no-repeat",
            "background-color": "currentColor",
            "vertical-align": "middle",
            display: "inline-block",
            width: size,
            height: size,
          };
        },
      }, { values });
    },
  };
}

function loadModule(candidates) {
  return async (id, base) => {
    let module;
    if (/(^|\/)heroicons(\.js)?$/.test(id)) module = await heroicons(candidates);
    else if (/daisyui-theme(\.js)?$/.test(id) || /daisyui\/theme$/.test(id)) module = (await import(`${DAISY}/theme/index.js/+esm`)).default;
    else if (/daisyui(\.js)?$/.test(id)) module = (await import(`${DAISY}/+esm`)).default;
    else if (!id.startsWith(".")) module = (await import(`https://cdn.jsdelivr.net/npm/${id}/+esm`)).default;
    else throw new Error(`studio: no plugin for @plugin "${id}"`);
    return { path: id, base, module };
  };
}

export async function run(base) {
  const started = performance.now();
  try {
    const source = await fetch(`${base}/__studio/css`, { cache: "no-store" }).then((r) => r.json());
    const candidates = [...new Set(source.text.split(/[\s"'`<>{}=;,\\]+/))].filter((c) => c && c.length < 200);
    const { compile } = await import(`${TW}/+esm`);
    const compiler = await compile(source.css, { base: "/", loadStylesheet, loadModule: loadModule(candidates) });
    const css = compiler.build(candidates);
    let style = document.getElementById("studio-tailwind");
    if (!style) {
      style = document.createElement("style");
      style.id = "studio-tailwind";
      document.head.append(style);
    }
    style.textContent = css;
    for (const link of document.querySelectorAll('link[rel="stylesheet"][href*="/assets/css/app.css"]')) link.disabled = true;
    console.debug(`studio: Tailwind compiled ${css.length} bytes in ${Math.round(performance.now() - started)} ms`);
    await fetch(`${base}/__studio/css`, { method: "PUT", body: css, headers: { "content-type": "text/css" } });
  } catch (err) {
    console.error("studio: the Tailwind step failed", err);
  }
}
