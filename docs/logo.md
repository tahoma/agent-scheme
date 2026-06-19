# The Consent Scheme logo

<p align="center">
  <img src="assets/consent-logo.png"
       alt="Consent Scheme logo: a yin-yang of a brush lambda and a single-stroke ensō dialog bubble"
       width="200">
</p>

The project mark is a yin-yang (taijitu) whose two dots have been replaced by
two glyphs: a brush **λ** in the light dot and a single-stroke **ensō dialog
bubble** in the dark dot, inside a thin neutral ring that keeps the disc legible
on any background. It is meant to reward a second look — most of what follows is
latent rather than announced.

## The mark

- **λ (lambda)** — the light ("yang") dot. The brushstroke lambda is the oldest
  sign for a function: the lambda calculus, and the Lisp family that grew out of
  it. Consent Scheme is an R7RS-small Scheme, so the function half of the symbol
  is literally the substrate the language stands on.
- **ensō dialog bubble** — the dark ("yin") dot. An *ensō* is the Zen circle
  drawn in a single brushstroke, traditionally left slightly open; the gap
  stands for movement and imperfection rather than closure. Here that open
  stroke doubles as a **dialog bubble**: the trailing spur turns the circle into
  a speech indicator, and "dialog" carries both the everyday sense (two parties
  in exchange) and the computing sense (the consent prompt — the *Allow / Deny*
  this runtime is built around).
- **the yin-yang** — opposites held in balance: code and data, function and
  dialogue, the actor and the act of approval. Capability security is exactly
  that balance, so the container is not decoration.

## logo, logos, λ

The wordplay is the point, and it nests.

**A logo is a *logos*.** The English word "logo" is a twentieth-century clipping
of *logogram* / *logotype*, from Greek **λόγος** (*logos*) — "word, speech,
reason, account." So "the project's logo" already says "the project's *logos*"
with no reaching at all.

**And *logos* begins with λ.** The lambda glyph is not only the lambda calculus;
it is the first letter of *logos* itself. The word that means *word-and-reason*
is captioned by the sign for *computation* — for a programming language, a happy
collision of reason and reckoning under a single letter.

**And *logos* splits along the seam.** Read across the taijitu, the one word
divides into its two ancient senses: *dia-logos* (*dia-*, "through" — reasoning
**through** exchanged speech) on the dialog-bubble side, and *logos* as reason
or account on the λ side. One word captions both dots at once.

So the figure is self-referential, which is the most fitting thing it could be
for a Lisp: **logo → logos → λ → the lambda calculus → the language whose logo
it is.** It is very nearly a quine — a mark that, unfolded, spells out its own
definition and points back at itself.

## logos and consent

The Greek idiom *logon didonai* — "to give a *logos*" — means to render an
account, to justify oneself. To consent, in the capability sense this runtime
cares about, is precisely that: a grant is an account asked for and given, and
the audit trail is the record of those accounts — the *logoi* kept. The
dialog-bubble half is where consent happens; the λ half is what it authorizes.

## logos and Tao

Heraclitus used *logos* for the unifying principle that holds opposites in
tension — the "hidden harmony" — which is close to what a taijitu draws. The
resonance runs deeper than coincidence. When the Gospel of John opens "In the
beginning was the *Logos*," the classic Chinese translations render it as
**太初有道** — "in the beginning was the **Tao** (道)." *Logos* becomes *Tao*.
So a yin-yang — the very sign of the Tao — cradling a **λ** — the initial of
*Logos* — is the same word twice, East and West, holding a *dia-logos* with
itself about what the ordering principle is.

Not bad for two dots and a brushstroke.

## The files

The artwork and the rasterization recipe live with the assets:

- `assets/consent-logo.svg` — the editable source of truth (a thin ring is added
  over the bare yin-yang so the near-white and near-black halves do not vanish
  into a light or dark page).
- `assets/consent-logo.png` — the derived raster embedded in the top-level
  [README](../README.md).
- [`assets/README.md`](assets/README.md) — the one-line regeneration command and
  the note on the ring.
