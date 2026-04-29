# GitHub Pages

Agent Operator Kit publishes a static site from the `site/` directory using GitHub Actions.

The deployment workflow lives at:

```text
.github/workflows/pages.yml
```

The public site is expected at:

```text
https://agent-operator-kit.github.io/operator-kit/
```

## How It Works

On every push to `main`, the workflow:

1. checks out the repository
2. configures GitHub Pages
3. copies `site/` into `_site/`
4. uploads `_site/` as a Pages artifact
5. deploys the artifact with GitHub Pages

## Repository Setting

In GitHub, set:

```text
Settings -> Pages -> Build and deployment -> Source -> GitHub Actions
```

This is a one-time repository setting. After that, pushes to `main` deploy the site.

## Local Preview

From the repository root:

```bash
python3 -m http.server 8080 --directory site
```

Then open:

```text
http://localhost:8080
```
