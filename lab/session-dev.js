/* The design lab outside the app: index.html#session=<name> loads a session exported by scripts/lab-session.sh. */
{ const m = location.hash.match(/session=([\w-]+)/); if (m) document.write(`<script src="sessions/${m[1]}.js"><\/script>`); }
