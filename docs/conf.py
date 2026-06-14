# Sphinx configuration for the claude-sandbox documentation site.
# Docs-only build: there is no Python package to autodoc.

# -- Project information -----------------------------------------------------
project = "claude-sandbox"
author = "Giles Knap"
html_title = "claude-sandbox"

# -- General configuration ---------------------------------------------------
extensions = [
    "myst_parser",
    "sphinx_design",
    "sphinx_copybutton",
    "sphinxcontrib.mermaid",
]

master_doc = "index"
exclude_patterns = ["_build", "Thumbs.db", ".DS_Store"]

# Don't fail the build on missing cross-references.
nitpicky = False

# -- MyST configuration ------------------------------------------------------
myst_enable_extensions = [
    "colon_fence",
    "deflist",
    "substitution",
    "attrs_inline",
]
myst_heading_anchors = 3

# -- HTML output -------------------------------------------------------------
html_theme = "pydata_sphinx_theme"
html_static_path = ["_static"]
html_css_files = ["custom.css"]
html_show_sphinx = False

html_theme_options = {
    "github_url": "https://github.com/gilesknap/claude-sandbox",
    "use_edit_page_button": True,
    "navigation_with_keys": False,
    "icon_links": [],
    "logo": {"text": "claude-sandbox"},
    "navbar_end": ["theme-switcher", "navbar-icon-links"],
}

# Wires up the "edit this page" button.
html_context = {
    "github_user": "gilesknap",
    "github_repo": "claude-sandbox",
    "github_version": "main",
    "doc_path": "docs",
}

# -- sphinx-copybutton -------------------------------------------------------
# Strip common interactive prompts so copied snippets are runnable.
copybutton_prompt_text = r">>> |\.\.\. |\$ |# "
copybutton_prompt_is_regexp = True

# -- sphinxcontrib-mermaid ---------------------------------------------------
mermaid_version = "11.4.1"
