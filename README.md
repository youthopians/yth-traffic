# YTH Project Management

Youthopians' internal tool for projects, tasks, reviews and team availability.

- **App:** https://youthopians.github.io/yth-traffic/
- **Hosting:** GitHub Pages (this repo, `main` branch, root folder)
- **Database and logins:** Supabase (project `ntkvbyolsbayiqbaskxx`). Data is never stored in this repo.
- **Security:** row-level security rules are in `supabase/schema.sql`. The key in `index.html` is Supabase's *publishable* key, which is designed to be public. Never commit the secret key.

To change the app, edit `index.html` and push to `main`; GitHub Pages republishes within a minute.
