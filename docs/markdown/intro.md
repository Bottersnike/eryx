# Intro to Markdown

Eryx provides a markdown parser and HTML renderer in [[@eryx/markdown]].

This parser supports CommonMark Markdown, along with most GitHub Flavored Markdown (GFM) extensions. It also supports a number of additional custom extensions and can make use of user-provided extensions too.

The rest of this page focuses on what's available from CommonMark and GFM in the parser.

## Headings

Headings break up your document into sections. There's one right above this line. Markdown supports up to 6 levels of headings, written as:

```
# First-level heading
## Second-level heading
### Third-level heading
#### Fourth-level heading
##### Fifth-level heading
###### Sixth-level heading
```

These headings can be used to generate an automatic table of contents for a page.

An alternative style for headings, matching setext, can be used:

```
First-level heading
===================

Second-level heading
--------------------
```

This style only supports two levels of headings.

## Inline styles

Inline styles can be used to decorate the text within a paragraph, adding **bold** or _italic_ text. The complete list of styles available is:

| Style           | Syntax                   | Output            |
| --------------- | ------------------------ | ----------------- |
| Bold            | `** .. **` or `__ .. __` | **Bold**          |
| Italic          | `* .. *` or `_ .. _`     | _Italic_          |
| Bold and italic | `*** .. ***`             | **_Bold italic_** |
| Inline code     | `` ` .. ` ``             | `Code`            |

## Quotes

To create a quote, prefix the line with `> `:

````
> I'm a quote
> > I'm a nested quote
> ## Quotes can contain other items
> ```
> Such as that heading, or this code
> ```
````

Renders as:

> I'm a quote
>
> > I'm a nested quote
>
> ## Quotes can contain other items
>
> ```
> Such as that heading, or this code
> ```

## Links

A basic link is defined using `[Text](http://example.org)` and renders as [Text](http://example.org). A title can be provided using `[Text](http://example.org "Title")`. Hover over [Text](http://example.org "Title") to view the title.

Links can be defined using shorthand: `<http://example.org>`, <http://example.org>.

The definition for a link can be defined on a different line:

```
A good example website is [foo] run by iana.

[foo]: http://example.com
```

> A good example website is [example] run by iana.
>
> [example]: http://example.org "Link title"

## Inline HTML

<div><center>I'm within a div</center></div>

## Extensions

By default, all built-in markdown extensions are enabled.

### Tables

Two style of tables are supported. The standard GFM style:

```
| Heading | Heading |
| ------- | ------- |
| Cell 1  | Cell 2  |
| Cell 3  | Cell 4  |
```

And the PHP markdown extensions style:

```
Heading | Heading
--------|--------
Cell 1  | Cell 2
Cell 3  | Cell 4
```

Both render the same:

> | Heading | Heading |
> | ------- | ------- |
> | Cell 1  | Cell 2  |
> | Cell 3  | Cell 4  |

A column can be centred by writing the heading underline as `:---:` instead of `-----`. For example

```
| Heading | Heading |
| :-----: | ------- |
| Cell 1  | Cell 2  |
| Cell 3  | Cell 4  |
```

Renders as

> | Heading | Heading |
> | :-----: | ------- |
> | Cell 1  | Cell 2  |
> | Cell 3  | Cell 4  |

### Strikethrough

Strikethrough adds GFM-style strike-through. Exactly one or two `~`s surrounding a piece of text will show it as ~~struck through~~. For example, `~foo~` and `~~foo~~`, but never `~~~foo~~~`.

### Colours

If a code block contains only a CSS colour, it will show a preview of that colour. For example: `#ff00ff`, `rgb(41, 170, 29)`, `hsl(34, 92%, 45%)`. Most CSS colour formats should be supported.

### Footnotes

Footnotes can be useful to reference information in a document that you don't want to present right away. They are defined using the following syntax:

```
Footnotes[^1] are cool.

[^1]: This is the footnote
```

Which renders as:

> Footnotes[^1] are cool.
> [^1]: This is the footnote

### Admonitions

An admonition allows you to place a chunk of text within a call-out box.

The following syntax is used to define one:

```
:::warning
This is a useful warning
:::
```

> :::warning
> This is a useful warning
> :::

The admonition type specified after `:::` can be anything you want, though eryxdoc supports the following list:

- `tip`
- `info`
- `note`
- `caution`
- `warning`
- `danger`

### Tabs

Tabs present multiple "pages" of content within a single tabbed notebook.

```
=== Tab 1
This is the content of tab 1
===

=== Tab 2
This is the content of tab 2
===
```

=== Tab 1
This is the content of tab 1
=== Tab 2
This is the content of tab 2
===

The closing `===` can be omitted if followed immediately by a new tab. On the occurrence where multiple tab groups follow each other with no other content between them, a new group can be forced using `===! Tab name`. The default-open tab is marked with `===+ Tab name`.

### Task lists

Task lists render as a normal list, but with checkboxes:

```
- [ ] Foo
- [ ] Bar
- [x] Buzz
- [ ] Bingo
```

> - [ ] Foo
> - [ ] Bar
> - [x] Buzz
> - [ ] Bingo

### WikiLinks

WikiLinks allow for custom internal links across a wiki (such as a documentation site). They are written as `[[reference]]`, or optionally as `[[reference|Display text]]`.

WikiLinks are the one extension that is not enabled by default, as a site-specific resolver is required. The site-specific resolver is used to resolve the `reference` into a URL.
