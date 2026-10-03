# beam.com

The WebAssembly runtime of [BEAM.com](https://github.com/sntran/BEAM.com)
for a native `app.com`, and `npx beam.com`.

BEAM.com is Erlang/OTP and Elixir in one executable file. `beam.com INPUT
-o app.com` builds a program into one file that runs natively, and the
same file also runs in the WebAssembly runtime of this package. The
version of this package is the version of `beam.com`.

## npx beam.com

```sh
npx beam.com app.erl -o app.com
npx beam.com mix phx.server
```

The package does not hold `beam.com` (about 50 MB). At the first run, it
downloads `beam.com` of the same version from the GitHub release, and
checks its SHA-256 against the value that the package holds. Then the
file stays in the cache (`~/.cache/beam.com/npm/`). A host that only
uses the runtime never downloads it.

- `BEAM_COM`: the path of a `beam.com` to use. Then nothing is
  downloaded.
- `BEAM_COM_DOWNLOAD`: the URL of a directory with the file `beam.com`,
  in place of the GitHub release.
- `BEAM_COM_CACHE`: the cache directory.

## The runtime in Node.js

Node.js 25 or later (for JSPI):

```js
import { boot } from 'beam.com/node';

const vm = await boot('app.com', { env: { PORT: '4000' } });
const response = await vm.fetch(new Request('http://localhost/'));
```

`boot` reads the file with a few reads (its end, its central directory,
and its release), and starts the VM. The file must come from `beam.com`
of the version of this package: a file for another runtime is an error.
`release(app)` gives the release of the file, without a VM.

## The files

| Import | What |
|---|---|
| `beam.com/node` | `boot`, `release`, `appRelease` and `runtimeId`, for Node.js. |
| `beam.com/app-com` | The reader of an `app.com`, for any host: `appRelease(read, size, { runtime })`. |
| `beam.com/runtime-id` | The identity of this runtime, for `appRelease`. |
| `beam.com/worker` | The runtime (`worker.js` of Cloudflare Workers). |
| `beam.com/beam.wasm` | The VM: ERTS built for WebAssembly. |

Not yet: an adapter for Cloudflare Workers, Deno, and a web page. Today,
`beam.com INPUT -o DIR --target wasm32` writes these hosts into `DIR`
(see [docs/WORKERS.md](https://github.com/sntran/BEAM.com/blob/main/docs/WORKERS.md)).

## License

Apache-2.0. `licenses/` has the license texts of the parts of the
runtime.
