# Setting up accounts (Firebase)

Idea Board's accounts and cloud boards run on Firebase's free **Spark** plan:

- **Firebase Authentication:** sign-up with email + password, email confirmation and
  password-reset emails (sent by Firebase, free).
- **Realtime Database:** boards, sharing and live cursors. The free plan includes 1 GB stored,
  10 GB downloaded per month and 100 people connected at once.

Until a Firebase config is added, the app works exactly as before: no sign-in, local boards
and peer-to-peer sessions only.

## 1. Create the project (about 5 minutes, in your browser)

1. Open https://console.firebase.google.com and click **Create a project**. Name it
   `Idea Board`. Google Analytics isn't needed, so you can switch it off.
2. **Turn on email sign-in:** *Build → Authentication → Get started → Sign-in method →
   Email/Password →* switch on the first toggle (leave "Email link" off) → **Save**.
3. **Create the database:** *Build → Realtime Database → Create Database →* location
   **Singapore (asia-southeast1)** → **Start in locked mode** → **Enable**.
4. **Add the security rules:** in the Realtime Database page open the **Rules** tab, replace
   everything with the contents of [`firebase/database.rules.json`](firebase/database.rules.json),
   and click **Publish**.
5. **Allow the website:** *Authentication → Settings → Authorized domains → Add domain →*
   `lemonspitz.github.io`.
6. **Get the web config:** click the gear icon → *Project settings → General → Your apps →*
   the web icon `</>` → nickname `Idea Board` → **Register app** (skip Hosting). Copy the
   `firebaseConfig = { … }` block it shows.

## 2. Put the config in the app

Paste the config into `Resources/web/index.html`, replacing `const FIREBASE_CONFIG = null;`:

```js
const FIREBASE_CONFIG = {
  apiKey: "…",
  authDomain: "idea-board-xxxx.firebaseapp.com",
  databaseURL: "https://idea-board-xxxx-default-rtdb.asia-southeast1.firebasedatabase.app",
  projectId: "idea-board-xxxx",
  // storageBucket, messagingSenderId, appId: fine to include, not used
};
```

Then run `./build.sh --install` and push to GitHub (the website copy is updated by the build).
The config is public by design: it only identifies the project. **Who can see what is decided by
the database rules**, not by keeping the config secret.

## Optional

- *Authentication → Templates*: change the sender name and wording of the confirmation and
  password-reset emails, and set the language (Indonesian is available).
- Free projects never expire, but keep an eye on *Usage* if many people use it. Images are
  stored inside the database, so boards with lots of photos use the 1 GB fastest.

## Who can do what (enforced by the rules)

| | Owner | Invited editor | Anyone else |
|---|---|---|---|
| Open and edit the board | ✓ | ✓ | ✗ |
| Rename the board | ✓ | ✓ | ✗ |
| Invite or remove people | ✓ | ✗ | ✗ |
| Delete the board | ✓ | ✗ (can only remove it from their own list) | ✗ |

Only signed-in users with a **confirmed** email address get any access, and an invitation only
works for the exact email it was sent to.

## Testing locally

`firebase emulators:start` in the `firebase/` folder (needs Node.js and Java) runs a local
copy of Authentication and the database with these rules. Open the web page with
`?emulator=1`, or start the Mac app with `IDEABOARD_EMULATOR=1`, to use it.
