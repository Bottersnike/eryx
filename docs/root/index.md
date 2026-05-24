---
hero:
  title: "@eryx/"
  description: "The Luau runtime that's useful."
  actions:
    - type: primary
      text: Get Started
      link: ./getting-started/welcome
    - text: Contribute
      link: https://github.com/Bottersnike/eryx
---
# Eryx

Eryx is a runtime designed to make Luau usable for serious desktop programming.

```luau
local http = require("@eryx/http")
local re = require("@eryx/regex")
local sqlite = require("@eryx/sqlite3")
local task = require("@eryx/task")
local pprint = require("@eryx/pprint")
local date = require("@eryx/date")

task.spawn(function(url: string)
    local res = http.get(url)
    local title = re.find("<title>(.*?)</title>", res.body)[1]

    local db = sqlite.open("crawls.db")
    db:exec("INSERT INTO pages VALUES(?, ?, ?)", url, title, date.now():toIsoString())
    db:close()

    pprint.pprint({ url=url, title=title })
end, "https://example.org")
```

All it takes is `@eryx/`. [[Welcome to Eryx|Get started now]].

<script>
(function() {
  var ua = navigator.userAgent;
  var url = /Windows/i.test(ua) ? 'https://github.com/Bottersnike/eryx/releases/download/nightly/eryx-standard-windows.zip'
          : /Linux/i.test(ua)   ? 'https://github.com/Bottersnike/eryx/releases/download/nightly/eryx-standard-linux.zip'
          : null;
  if (!url) return;
  var actions = document.querySelector('.md-hero-actions');
  if (!actions) return;
  var a = document.createElement('a');
  a.className = 'md-hero-action';
  a.href = url;
  a.textContent = 'Download';
  actions.insertBefore(a, actions.lastElementChild);
})();
</script>