// /privacy (spec §4.I): "What Metal-PT sends", in plain words.
import { Layout } from "./layout.tsx";

export function PrivacyPage() {
  return (
    <Layout title="What Metal-PT sends" section="privacy" description="What the Metal-PT app sends when you publish a run, what is public, and what is never stored.">
      <article class="privacy">
        <h1>What Metal-PT sends</h1>
        <p>
          Nothing leaves your Mac until you press Publish on a run in the Metal-PT app. Then the app sends that one run:
          its recording file and the numbers worked out from it. This page says what becomes public and what doesn't.
        </p>

        <h2>Public, on the run's page and in its download</h2>
        <ul>
          <li>Your Mac's model, chip, GPU cores and memory, and the macOS version.</li>
          <li>The setup: native, or the Wine runtime (CrossOver, Whisky…) with its version and graphics layers.</li>
          <li>The game's title and its settings: preset, resolution, upscaler, frame generation.</li>
          <li>The per-second numbers recorded during the run, such as frame rate, power and GPU clock.</li>
          <li>Your run label and game-settings text, if you wrote them.</li>
          <li>Your notes, only if you ticked the box to include them.</li>
          <li>A YouTube link, if you add one: the site keeps the video's ID, title and channel, not the text you typed.</li>
        </ul>
        <p>The run's page has a Download link to the same .mptrun.zip file the app uploaded.</p>

        <h2>Never public</h2>
        <ul>
          <li>
            The key that signs your runs. It is made by the app on your Mac and lets the site count one Mac once and
            let only you change or remove your runs. It is used inside the site only.
          </li>
          <li>
            Anything the app removes before sending: your user name, your Mac's name and folder paths in your home
            folder. The site checks text again for names and paths and removes any it finds.
          </li>
          <li>Run pages show no Mac identity beyond the model.</li>
        </ul>

        <h2>Never stored</h2>
        <ul>
          <li>Never stored: IP addresses, user agents or cookies.</li>
          <li>No analytics or tracking scripts on any page.</li>
          <li>
            The pages load nothing from other sites except the typefaces from Google Fonts, and, on the "Report a
            problem" form only, Cloudflare Turnstile (from challenges.cloudflare.com), which checks that a person is
            sending the report. Video links open YouTube in a new tab; no YouTube player is put in the page.
          </li>
        </ul>

        <h2>Reporting a problem with a run</h2>
        <p>
          Each run page has a "Report a problem" link. A report keeps the run, the reason you picked, your words (with
          names and folder paths removed) and the time: nothing about who sent it. Turnstile runs in your browser and
          talks to Cloudflare directly; the site passes Cloudflare only the check's answer, never your address.
          Reports are read by hand; a run can be hidden and a video link removed.
        </p>

        <h2>Removing a run</h2>
        <p>
          Remove a run from the Metal-PT app at any time: its page, its file and its part in every typical figure are
          deleted. Pages can take up to a minute to catch up.
        </p>

        <h2>How far to trust the numbers</h2>
        <p>
          Every run is signed by the app that recorded it, and the site checks the headline numbers against the
          recording before it shows them. Each Mac counts once in a typical figure, and runs far from the rest are
          set aside as outliers. That makes a figure hard to move by accident or by one person, but it is not proof:
          treat a typical figure as what people with that Mac have seen.
        </p>
      </article>
    </Layout>
  );
}
