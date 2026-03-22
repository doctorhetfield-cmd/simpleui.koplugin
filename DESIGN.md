# Design System Document: The Editorial E-Ink Experience

## 1. Overview & Creative North Star: "The Digital Papyrus"

The "Digital Papyrus" is the Creative North Star for this design system. We are not building a generic tablet app; we are crafting a high-end, tactile reading experience that honors the heritage of print while embracing the limitations of E-Ink technology. 

By leaning into the constraints of grayscale, zero shadows, and no gradients, we move away from "flat UI" into "Intentional Brutalism." We break the "template" look by using aggressive white space, stark tonal shifts, and an obsession with typographic rhythm. This system prioritizes the physical sensation of ink on a page over the artificial glow of a liquid crystal display.

---

## 2. Colors: The High-Contrast Grayscale Palette

In an E-Ink environment, color is a distraction. Our palette is a clinical study in black, white, and deliberate grays.

### The Palette
*   **Background:** `#f9f9f9` (The canvas)
*   **Primary:** `#000000` (The ink)
*   **Surface Tiers:** 
    *   `surface_container_lowest`: `#ffffff`
    *   `surface_container_low`: `#f3f3f4`
    *   `surface_container`: `#eeeeee`
    *   `surface_container_high`: `#e8e8e8`
    *   `surface_container_highest`: `#e2e2e2`
*   **On-Surface (Text):** `#1a1c1c`

### The "No-Line" Rule
Prohibit the use of 1px solid borders for sectioning. Traditional borders create visual noise on E-Ink displays during refresh cycles. Boundaries must be defined solely through background color shifts. To separate a header from a list, transition from `surface` to `surface_container_low`. 

### Surface Hierarchy & Nesting
Treat the UI as a series of stacked sheets of fine paper. Use `surface_container_lowest` (#ffffff) for active reading areas to maximize contrast. Use higher tiers like `surface_container_highest` (#e2e2e2) for utility bars and navigation to "push" them into the background relative to the content.

---

## 3. Typography: The Editorial Voice

We utilize a dual-font strategy to balance the classic feel of a book with the precision of a digital interface.

### The Scale
*   **Display (Lg/Md/Sm):** `newsreader`. Use for book titles and chapter starts. These should be large and authoritative to anchor the page.
*   **Headline & Title:** `newsreader`. Serif fonts provide the "literary" feel necessary for an e-reader.
*   **Body (Lg/Md/Sm):** `newsreader`. Optimized for long-form legibility with generous leading.
*   **Labels (Md/Sm):** `publicSans`. A clean, sans-serif choice for metadata (page numbers, clock, battery) to distinguish UI from Content.

### Intentional Asymmetry
Avoid centering everything. Use left-aligned headlines with exaggerated top margins (`spacing-16`) to create a bespoke, editorial layout that feels curated rather than generated.

---

## 4. Elevation & Depth: Tonal Layering

Since shadows and gradients are forbidden, depth is achieved through **Tonal Layering**.

*   **The Layering Principle:** Place a `surface_container_lowest` card on a `surface_container_low` background. The subtle 3-4% shift in gray value is enough for the human eye to perceive "lift" without the "muddy" look of E-Ink shadows.
*   **The "Ghost Border" Fallback:** If a divider is strictly required for accessibility (e.g., in a dense settings menu), use the `outline_variant` (#c6c6c6). Do not use pure black for lines; it creates too much visual weight.
*   **Flatness as Premium:** Embrace the 2D nature. Use large blocks of `#000000` for primary actions to create "holes" in the white page, drawing the eye instantly.

---

## 5. Components

### Buttons
*   **Primary:** Solid `primary` (#000000) background with `on_primary` (#e2e2e2) text. Square corners (`0px`).
*   **Secondary:** `surface_container_highest` background with `on_surface` text. No border.
*   **Tertiary:** Text only, bolded `label-md` in all caps for clear affordance.

### Input Fields
*   **Style:** Avoid "box" inputs. Use a `surface_container_high` background with a 2px `primary` bottom-bar only. This mimics a signature line on a document.

### Cards & Lists
*   **Rule:** Forbid divider lines.
*   **Implementation:** Use `spacing-4` or `spacing-5` between list items. Separate different book categories by shifting the background of the entire section to `surface_container_low`.

### The "Reading Progress" Bar
*   Avoid thin lines. Use a thick, chunky horizontal block of `primary_container` (#3b3b3b) with the progress filled in `primary` (#000000). It must be unmistakable even at low refresh rates.

### Selection Chips
*   **Unselected:** `surface_container_highest`.
*   **Selected:** `primary` (#000000) with `on_primary` (#e2e2e2) text. The high contrast change signals the state change clearly.

---

## 6. Do's and Don'ts

### Do:
*   **Do** use extreme white space. E-ink pixels are "free"; don't crowd the screen.
*   **Do** use `newsreader` for everything that is "content" and `publicSans` for everything that is "tool."
*   **Do** use the `0.7rem` to `1.4rem` spacing range for most padding to ensure a breathable, premium feel.

### Don't:
*   **Don't** use 1px lines. They often "ghost" or appear jagged on 212-300 DPI E-Ink screens.
*   **Don't** use any rounded corners. This system is architectural and sharp. `0px` is the only value.
*   **Don't** use gray text on gray backgrounds. Maintain a minimum contrast ratio of 7:1 for all UI elements to account for the lower contrast of physical E-ink film compared to OLED.