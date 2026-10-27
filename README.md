![Header Image](.gdignore/assets/social.png)

# Godot PostHog Analytics

A [Godot](https://godotengine.org/) addon to quickly add
[PostHog](https://posthog.com/) analytics to any project.

This addon has no official affiliation with Godot or PostHog.

## Why have analytics?

Analytics allow you to capture insightful metrics about how users interact with
your application or game. For example, you could measure:

- How many times your application is opened
- How many times a game is started
- What OS/Platform are users playing your game on
- How many levels players are completing in your game
- How many times players fail a certain level
- Etc.

PostHog provides a generous **free tier** that most small applications and games
can utilize. See [PostHog Pricing](https://posthog.com/pricing).

## Disclaimer

Please be aware that the implementation and use of analytics within your game
are your sole responsibility. This library provides tools to collect and
potentially transmit data, but it does not ensure compliance with any specific
privacy laws or regulations (such as GDPR, CCPA, etc.).

**It is your responsibility to:**

- Understand and comply with all applicable laws and regulations regarding data
  collection, storage, and usage in your target markets.
- Obtain any necessary user consent for data collection.
- Provide clear and transparent information to your users about the data you are
  collecting and how it will be used.
- Ensure the security and privacy of any collected data.

The developers of this library assume no liability for your implementation or
any failure to comply with relevant legal and ethical standards. Use this
library responsibly and with due diligence.

As a starting point, consider reading
[PostHog's Privacy Compliance documentation](https://posthog.com/docs/privacy).

## Setup

### PostHog Project

If you don't already have one, create a [PostHog](https://posthog.com/) account
an organization. You can create one organization for each Godot project.

### Download the addon

- Download the repository
  - See
    [Downloading a repository's files](https://docs.github.com/en/get-started/start-your-journey/downloading-files-from-github#downloading-a-repositorys-files)

### Godot Project

- Place the `PostHog` directory in your project's `addons` directory
- Add `res://addons/Posthog/post_hog.gd` as an
  [Autoload](https://docs.godotengine.org/en/stable/tutorials/scripting/singletons_autoload.html)
  with the name `PostHog`

### config.cfg

Copy `addons/PostHog/config.example.cfg` to `addons/PostHog/config.cfg` and fill in
`apiKey` and `baseUrl` (section `[posthog/config]`). Without both keys the plugin
stays disabled and `capture()` does nothing.

```ini
[posthog/config]
apiKey="<POSTHOG_PROJECT_API_KEY>"
baseUrl="https://eu.i.posthog.com"
debug=false
```

With `debug=true`, events are written to `user://posthog_debug/` instead of being sent.

You can find your project API key under the PostHog organization's default
project settings. Or try this url with your project ID:

```
https://us.posthog.com/project/<PROJECT_ID>/settings/project#variables
```

> [!IMPORTANT]
> `config.cfg` is git-ignored: never commit your project API key. In CI, write the
> file from a secret before exporting.

As of April 2025, your `baseUrl` should be either `https://us.i.posthog.com`
for US Cloud or `https://eu.i.posthog.com` for EU Cloud. From your project
dashboard, the url should signal which Cloud you are using. See the
[PostHog API endpoint documentation](https://posthog.com/docs/api/capture) to
verify what `base_url` should be used. **Don't include the path** (`/i/v0/e` or
`/batch`).

## Usage

### Capture

In any script, you can start capturing events:

```gdscript
# Any event (String)
PostHog.capture("event_name")

# With extra properties (Dictionary)
PostHog.capture("event_name", {
  "level_name": level_name,
})
```

### Auto include properties

If you have something you want recorded with every event, add it to the
`PostHog.auto_include_properties` Dictionary. **Reminder:** consider any
compliance requirements before you included identifiable data.

```gdscript
PostHog.auto_include_properties["distribution_platform"] = "itchio"
```

Every event captured after this will contain properties from this Dictionary.
They can be erased.

```gdscript
PostHog.auto_include_properties.erase("distribution_platform")
```

### Anonymous events

[Anonymous events](https://posthog.com/docs/data/anonymous-vs-identified-events)
are enabled by default. Change the `anonymous_events` member variable to change
this behavior. **Reminder:** consider any compliance requirements when switching
to
[identified events](https://posthog.com/docs/data/anonymous-vs-identified-events).

```gdscript
# Use identified events.
PostHog.anonymous_events = false
```

### Error tracking

Send exceptions as `$exception` capture events (usable in the PostHog
[Error Tracking](https://posthog.com/docs/error-tracking) section):

```gdscript
# type, message, optional stacktrace (parsed into frames), optional extra properties
PostHog.capture_exception("ScriptError", "Failed to connect", "res://net.gd:42:in _connect")
```

The stacktrace is a multiline string; simple `filename:line[:in function]` lines
are turned into stack frames. A SHA-256 `$exception_fingerprint` is derived from
the type + message to group identical issues.

### Logs (OpenTelemetry)

PostHog ingests
[logs](https://posthog.com/docs/logs) over OTLP JSON. This addon exposes a
`log()` helper for the `https://<region>.i.posthog.com/i/v1/logs` endpoint:

```gdscript
# message, LogLevel, optional attributes
PostHog.log("Connection lost", PostHog.LogLevel.ERROR, {"scene": "home", "retry": 3})
```

Available `LogLevel` values: `TRACE` (1), `DEBUG` (5), `INFO` (9), `WARN` (13),
`ERROR` (17), `FATAL` (21) — matching the
[OpenTelemetry severity scale](https://opentelemetry.io/docs/specs/otel/logs/data-model/).

`min_log_level` discards records below a threshold (default `DEBUG`). `app_name`
is sent as the OTLP `service.name` resource attribute, and the project version
(`application/config/version`) as `service.version`.

Log endpoints require an `Authorization: Bearer <project_token>` header, which
this addon attaches automatically. Log calls are skipped on `web` builds.

### Feature flags

[Feature flags](https://posthog.com/docs/feature-flags) are fetched from the
`/flags` endpoint at startup (and again after `identify()` / `reset()`), cached
in `user://posthog_flags.json` so they are available offline, and kept in memory.

```gdscript
# Boolean flag (second argument: value while the flag is unknown / not loaded yet)
if PostHog.is_feature_enabled("new_shop", false):
    show_new_shop()

# Raw value: true / false, the variant String of a multivariate flag, or null if unknown
var value = PostHog.get_feature_flag("new_shop")

# Payload configured on the flag in PostHog (JSON parsed)
var config = PostHog.get_feature_flag_payload("daily_reward")

# React when flags arrive (first response, cache restore, overrides)
PostHog.feature_flags_loaded.connect(_apply_flags)

# Refresh manually
PostHog.reload_feature_flags()
```

Reading a flag sends a `$feature_flag_called` event once per flag and value, and
every captured event carries `$active_feature_flags` and `$feature/<key>`, so
PostHog can break any insight down by flag.

Target flags with person properties: the app version, OS, device type and
platform are sent automatically; add your own with
`PostHog.set_feature_flag_person_properties({"plan": "pro"})`.

Force a value locally while testing (it wins over PostHog and sends no event):

```gdscript
PostHog.override_feature_flag("new_shop", true)
PostHog.clear_feature_flag_overrides()
```

### Experiments

An [experiment](https://posthog.com/docs/experiments) is a multivariate feature
flag. Create it in PostHog (Experiments), then read the variant the player is in:

```gdscript
match PostHog.get_experiment_variant("reward_amount"):  # "control" when unknown
    "double":
        reward = 200
    _:
        reward = 100

# Goal metric: a normal event, attributed to the variant automatically
PostHog.capture("reward_claimed", {"amount": reward})
```

Call `get_experiment_variant()` (or `get_feature_flag()`) at the moment the
player is actually exposed to the change, not at startup: the first call sends
the `$feature_flag_called` exposure event that PostHog uses to count participants.

Options in `config.cfg` (all optional):

| Key | Default | Effect |
| --- | --- | --- |
| `flagsEnabled` | `true` | Turns feature flags and experiments off entirely |
| `flagsAutoLoad` | `true` | Fetch at startup and after `identify()` / `reset()` |
| `flagsAttachToEvents` | `true` | Add `$active_feature_flags` / `$feature/<key>` to events |

In `debug = true` mode nothing is fetched; use `override_feature_flag()`.

## PostHog dashboards

To see your metrics in PostHog, create a new
[insight](https://posthog.com/docs/product-analytics/insights) with your event
name. Add the insight to your
[dashboard](https://posthog.com/docs/product-analytics/dashboards).

Creating an insight:

![PostHog Insight Example](.gdignore/assets/godot_posthog_insight_example.png)

Dashboard example:

![PostHog Dashboard Example](.gdignore/assets/godot_posthog_dashboard_example.png)

## License

MIT License. See [LICENSE.txt](addons/PostHog/LICENSE.txt)
