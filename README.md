<div align="center">

# Local Hosting

**Servers and Databases for macOS**

[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-FFDD00?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/eduardmpopescu)
![macOS 15+](https://img.shields.io/badge/macOS-15%2B-lightgrey)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)

</div>

Local Hosting is a Mac app for running websites and databases on your own machine. You add a site, flip a switch, and it's live on the address you picked, over HTTPS. Flip it off and the address goes back to normal. Databases work the same way, and you can browse and query them inside the app.

If this saves you some setup time, you can [buy me a coffee](https://buymeacoffee.com/eduardmpopescu).

## What it does

- Runs PHP, static, Node, Python and Ruby sites with Apache or Nginx.
- Runs MySQL, PostgreSQL, MongoDB, Redis and SQLite databases, each with its own on/off switch.
- Lets you browse tables, collections and keys, and run queries, without logging in to anything.
- Shows live logs for every server and database.
- Can take over a real hostname (say `example.com`) while its server is on, and gives it back when you switch off.
- Creates its own HTTPS certificates that your Mac trusts.

## Requirements

- macOS 15 or later
- Xcode Command Line Tools (`xcode-select --install`)
- [Homebrew](https://brew.sh). The app can install it for you.

## Install

### Download

1. Get `Local-Hosting-1.0.1.zip` from the [latest release](https://github.com/eduardmpopescu/Local-Hosting/releases/latest) and unzip it.
2. Drag **Local Hosting** to your Applications folder.
3. Open the app. macOS will say it can't verify it, because the app is signed ad hoc. Click **Done**, then open **System Settings → Privacy & Security**, scroll down to the message about Local Hosting and click **Open Anyway**. Confirm with your password. You only need to do this once.

The download is for Apple Silicon Macs. On an Intel Mac, build it yourself.

### Build it yourself

```bash
git clone https://github.com/eduardmpopescu/Local-Hosting.git
cd Local-Hosting

./build.sh             # builds "build/Local Hosting.app"
./build.sh --install   # also copies it to /Applications
```

## First run

Open **Settings** (⌘,). It lists everything the app needs, each item with its own **Install** button. Install only what you plan to use.

1. **Software.** Homebrew, Apache, Nginx, PHP 8.1 to 8.5, Node, Python, Ruby and the database engines.
2. **HTTPS certificates.** Creates a certificate authority that only exists on your Mac and trusts it in your login keychain. After that, `https://` works on every site.
   In Firefox, set `security.enterprise_roots.enabled` to `true` in `about:config`.
3. **Address helper.** Asks for your password once, then installs `/usr/local/libexec/localhosting-helper` and `/etc/sudoers.d/localhosting`. The helper can only add or remove hostnames that point to `127.0.0.1` or `::1`, inside a marked block of `/etc/hosts`.

Settings keeps itself up to date, even when you install or remove things outside the app.

## Servers

A server has a name, an address, a type, a web server and a folder.

| Type | What it runs |
|---|---|
| PHP | The PHP files in the folder, with the PHP version you pick |
| Static | Plain HTML, CSS and JavaScript, served as is |
| Node, Python, Ruby | Your own project. The app runs its start command and the web server forwards the address to the port it listens on |

### Apache and Nginx

Both need ports 80 and 443, so only one can run at a time. When you switch on a server, the running servers that use the other web server are switched off. Nginx uses a generated config that sends missing files to `index.php` (so Laravel, WordPress and similar work) and it ignores `.htaccess`.

### PHP

You can run several PHP versions at once and pick one per server. The default is the newest one you have installed. The app starts one PHP-FPM process per version in use, and stops it when the last server using it goes off.

PHP settings come from Homebrew's `php.ini` for that version (`$(brew --prefix)/etc/php/<version>/`), so any extensions you add there are picked up. Upload size, post size and memory limit are set by the app to 256M, 256M and 512M.

PHP doesn't run inside Apache anymore, so `php_value` and `php_flag` lines in `.htaccess` are ignored. Either wrap them in `<IfModule mod_php.c>` or move them to a `.user.ini` file in the site's folder.

### Node, Python and Ruby

Give the server a **command** that starts your project and a **port**. The port is also passed to the command as `$PORT`, so `npm start`, `flask run -p $PORT` and `bundle exec rails server -p $PORT` all listen where the web server expects.

- The command runs in your login shell, so nvm, pyenv and rbenv are found. If you don't use them, the app falls back to Homebrew's copy, which you can install in Settings.
- The project starts when you switch the server on. It stops, along with everything it started, when you switch the server off or quit the app.
- If the command fails straight away, the app tells you why. Its output shows up in the Console's **Apps** tab. WebSockets work.

### Addresses

- Switching a server on points its address at your Mac. For a bare domain like `example.com`, `www.` is included. Switching it off removes them, and a real website on that address comes back right away.
- Sites can only be opened from your Mac, not from other devices on your network.
- Once the certificate authority is trusted, `http://` addresses redirect to `https://`. The redirect is temporary (302), so browsers forget it after you switch the server off.
- If a browser still shows the old site right after you switch, reload or open a new tab. Browsers sometimes keep an open connection or a cached page.
- Quitting the app stops everything and restores `/etc/hosts`. Closing the window doesn't quit; open it again from the Dock.

## Databases

Every engine runs as its own private server with its own data folder, separate from any Homebrew service you already have. An engine starts when you switch on its first database and stops when you switch off its last.

| Engine | Default port | Login |
|---|---|---|
| MySQL | 3306 | A user and password for each database |
| PostgreSQL | 5432 | A user and password for each database |
| MongoDB | 27017 | A user and password for each database |
| Redis | 6379 | The server's password. Each database is a numbered Redis database |
| SQLite | none | A file the app keeps. Nothing to install |

A database that's switched off refuses connections from its user, but its data stays on disk. Click a user or password on a card to copy it. You can change a password from the card's right-click menu, and change an engine's port in **Databases**. Each page also shows how much memory the server uses and how much disk space the database takes.

An example in PHP:

```php
$pdo = new PDO('mysql:host=localhost;dbname=mydb;charset=utf8mb4', 'myuser', 'mypassword');
```

MongoDB's server isn't in Homebrew's own list, so it comes from MongoDB's tap, `mongodb/brew`. The app adds the tap and trusts three of its packages by name: the server, the database tools, and the enterprise edition that the server checks for conflicts. Nothing else from the tap is trusted.

## Browser

The Browser opens any of your databases. It signs in for you with an account the app keeps in the background, so there's nothing to type.

- **Rows** shows the contents of a table, collection or key, 100 per page. Click a column name to sort. Row counts are exact, except for very large tables, where the engine's estimate is shown with a `~`. Reload with ⌘R.
- **Structure** shows columns, types, keys, defaults and indexes. For Redis it shows the key's type, TTL, encoding and memory use.
- **SQL** (or **Query** / **Commands**) runs statements against the selected database and shows the results. It takes SQL for MySQL, PostgreSQL and SQLite, `mongosh` statements for MongoDB and Redis commands for Redis.

**Browse** on a database page, or in its right-click menu, opens that database in the Browser and switches it on if it was off.

## Console

The Console has a tab for each log: your servers (Apache or Nginx, whichever ran last), PHP, your apps and each database engine. It updates live. PHP errors, warnings and `error_log()` messages from every PHP version end up in the PHP tab, with errors in red and warnings in orange. Scroll up to pause the log and scroll back down to resume. The eraser button empties the log file.

## Where things live

| Location | What's there |
|---|---|
| `~/Library/Application Support/Local Hosting/` | Settings, web server and PHP configs, logs, database data, certificates |
| `~/Sites/<server>` | The default folder for a new server |
| `/usr/local/libexec/localhosting-helper` | The address helper |
| `/etc/sudoers.d/localhosting` | Lets the helper run without asking for your password |

## Security

- The certificate authority and its key stay on your Mac, and only your login keychain trusts it.
- The address helper can only edit its own block in `/etc/hosts`, and only with loopback addresses.
- Servers listen on `127.0.0.1` and `::1`, so nothing is open to your network.
- The app isn't sandboxed. It needs `/etc/hosts`, a privileged helper, a keychain certificate authority, Homebrew binaries and ports 80 and 443, none of which the sandbox allows. That also rules out the Mac App Store.

## Uninstall

1. Remove the address helper:
   ```bash
   sudo rm /usr/local/libexec/localhosting-helper /etc/sudoers.d/localhosting
   ```
2. In Keychain Access, delete the **Local Hosting CA** certificate.
3. Delete the app and `~/Library/Application Support/Local Hosting`.

Anything you installed with Homebrew stays. Remove it with `brew uninstall` if you don't want it.

## Project layout

```
Sources/LocalHosting/   the SwiftUI app: views, plus the code for each server and database engine
Resources/              Info.plist and the app icon
build.sh                builds and signs the app bundle
Package.swift           Swift package manifest
```

## Contributing

Issues and pull requests are welcome. If you're planning something big, open an issue first so we can talk about it.

When you test, point the app at a separate data folder so your real servers and databases stay untouched:

```bash
LOCAL_HOSTING_DATA_DIR="$HOME/Library/Application Support/Local Hosting Test" \
  "build/Local Hosting.app/Contents/MacOS/LocalHosting"
```

## License

Released under the [MIT License](LICENSE).
