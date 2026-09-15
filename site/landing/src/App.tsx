import { useEffect, useState } from 'react'

const REPO = 'manuelvegadev/OpenBeam'
const GITHUB = `https://github.com/${REPO}`
const RELEASES = `${GITHUB}/releases`
const DMG = `${RELEASES}/latest/download/OpenBeam.dmg`
// Vite already owns the Pages base path; spelling it out again would survive a
// rename as a broken link, because absolute strings are not rewritten.
const BASE = import.meta.env.BASE_URL
const DOCS = `${BASE}docs/`

/** One end of the signal path. The two differ only in their accent and rows. */
function Station({
  tone,
  title,
  rows,
}: {
  tone: 'send' | 'receive'
  title: string
  rows: [string, string][]
}) {
  return (
    <div className={`station station-${tone}`}>
      <div className="station-head">
        <i className="lamp" aria-hidden="true" />
        {title}
      </div>
      <dl>
        {rows.map(([term, value]) => (
          <div key={term}>
            <dt>{term}</dt>
            <dd>{value}</dd>
          </div>
        ))}
      </dl>
    </div>
  )
}

/**
 * The published version, read from the releases API.
 *
 * The download link never depends on this — it points at `latest` and works
 * whether or not the request succeeds — so a rate-limited or offline visitor
 * gets a page that is one line shorter rather than a broken one.
 */
function useLatestVersion() {
  const [version, setVersion] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    fetch(`https://api.github.com/repos/${REPO}/releases/latest`)
      .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
      .then((r: { tag_name?: string }) => {
        if (!cancelled && r.tag_name) setVersion(r.tag_name.replace(/^v/, ''))
      })
      .catch(() => {})
    return () => {
      cancelled = true
    }
  }, [])

  return version
}

export default function App() {
  const version = useLatestVersion()

  return (
    <>
      <header className="wrap masthead">
        <a className="wordmark" href={BASE}>
          <img src={`${BASE}icon.png`} alt="" width={26} height={26} />
          OpenBeam
        </a>
        <nav>
          <a href={DOCS}>Docs</a>
          <a href={GITHUB}>GitHub</a>
          <a href={RELEASES}>Releases</a>
        </nav>
      </header>

      <main>
        <div className="wrap hero">
          <h1>
            <span>The camera is on that Mac.</span>
            <span>The call is on this one.</span>
          </h1>
          <p>
            OpenBeam publishes a camera as an NDI source on your local network, and turns any
            source on that network back into a webcam. Two Macs, no capture card, no OBS.
          </p>

          <div className="path">
            <Station
              tone="send"
              title="Sending"
              rows={[
                ['Source', 'macos-studio'],
                ['Camera', 'Insta360 Link'],
                ['Format', '1920×1080 BGRA'],
              ]}
            />

            <div className="link" aria-hidden="true">
              <span>local network</span>
            </div>

            <Station
              tone="receive"
              title="Receiving"
              rows={[
                ['Source', 'macos-studio'],
                ['Camera', 'NDI Virtual Camera'],
                ['Seen by', 'Zoom, Meet, Teams'],
              ]}
            />
          </div>

          <div className="actions">
            <a className="download" href={DMG}>
              Download for macOS
            </a>
            <p className="meta">
              {version ? `Version ${version}. ` : ''}
              Free and open source. Requires macOS 15.
            </p>
          </div>
        </div>

        <section className="wrap">
          <h2>One app, two jobs</h2>
          <div className="roles">
            <div className="role role-send">
              <h3>
                <i className="lamp" aria-hidden="true" />
                Send
              </h3>
              <p>
                Pick a camera and a microphone. OpenBeam advertises them under your machine's
                name, and anything that speaks NDI can pick them up — another Mac, OBS, a
                hardware receiver.
              </p>
              <p>
                <strong>macOS camera effects come along.</strong> Portrait, Studio Light, Centre
                Stage and Reactions apply to what goes out, because the frames are taken after
                macOS has finished with them.
              </p>
            </div>
            <div className="role role-receive">
              <h3>
                <i className="lamp" aria-hidden="true" />
                Receive
              </h3>
              <p>
                Choose a source and it becomes a webcam for every app on the machine. Your call
                app sees a camera called NDI Virtual Camera and a microphone called NDI Audio.
              </p>
              <p>
                <strong>The video never passes through OpenBeam.</strong> It goes straight from
                the network into the camera extension, which keeps working after OpenBeam quits.
              </p>
            </div>
          </div>
        </section>

        <section className="wrap">
          <h2>Also in the menu bar</h2>
          <dl className="capabilities">
            <div>
              <dt>Live preview and meters</dt>
              <dd>
                The menu carries a moving preview, an audio level meter, and statistics for
                resolution, frame rate, data rate and dropped frames.
              </dd>
            </div>
            <div>
              <dt>Clipboard sync</dt>
              <dd>
                Copy on one machine, paste on another. Devices are paired by hand, and the
                connection between them is encrypted.
              </dd>
            </div>
            <div>
              <dt>Updates that wait their turn</dt>
              <dd>
                OpenBeam checks daily and adds a line to its menu. It never interrupts a call to
                tell you, and every update is verified against a key built into the app.
              </dd>
            </div>
            <div>
              <dt>Nothing else running</dt>
              <dd>
                Native AppKit, no Electron, no browser engine. Frames go to NDI without a
                compositing pass.
              </dd>
            </div>
          </dl>
        </section>

        <section className="wrap">
          <h2>Get started</h2>
          <ol className="steps">
            <li>
              <div>
                <h3>Install it on both Macs</h3>
                <p>
                  Open the disk image and drag OpenBeam to your Applications folder. Open it from
                  there, so it can keep itself up to date.
                </p>
              </div>
            </li>
            <li>
              <div>
                <h3>Allow it to open</h3>
                <p>
                  OpenBeam is not signed with a paid Apple certificate, so the first launch needs
                  one trip through System Settings → Privacy &amp; Security → Open Anyway.
                </p>
              </div>
            </li>
            <li>
              <div>
                <h3>Send on one, receive on the other</h3>
                <p>
                  Pick a camera on the sending Mac, pick that source on the receiving one, and
                  choose NDI Virtual Camera in your call app. Receiving needs{' '}
                  <a href="https://ndi.video/tools/">NDI Tools</a> installed once.{' '}
                  <a href={DOCS}>Read the guide</a>.
                </p>
              </div>
            </li>
          </ol>
        </section>
      </main>

      <footer className="wrap">
        <p>OpenBeam is built by Manuel Vega and is free to use, modify and share.</p>
        <nav>
          <a href={DOCS}>Docs</a>
          <a href={GITHUB}>Source</a>
          <a href={`${GITHUB}/issues`}>Report an issue</a>
        </nav>
      </footer>
    </>
  )
}
