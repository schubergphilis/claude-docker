## MODIFIED Requirements

### Requirement: The distribution channel is documented

The project's README SHALL document the published image as an install path: the reference to
pull, the tag scheme a consumer must pin, the architectures published, which of them the
scanners cover, and how to point the wrapper at a published image instead of a locally built
one. It SHALL also document the Homebrew install as an install path, the published image it
runs by default, and how to override that image.

Building the image locally SHALL remain a supported and documented path. The published image
is an addition to it, not a replacement, and the wrapper script SHALL keep defaulting to the
locally built tag. Only the Homebrew-installed command defaults to a published image, the one
of its own version.

#### Scenario: a new user chooses an install path

- **WHEN** a user reads the README's install documentation
- **THEN** Homebrew, building locally and pulling the published image are presented as
  supported
- **AND** the pull path states the reference, the tag to pin, and the architectures covered

#### Scenario: pointing the wrapper at the published image

- **GIVEN** a published image
- **WHEN** a user wants the wrapper to run it instead of a locally built one
- **THEN** the README names the existing image override for doing so
- **AND** the wrapper's default behaviour is unchanged for users who do not set it

#### Scenario: a Homebrew user learns which image they run

- **WHEN** a user reads the Homebrew install documentation
- **THEN** it names the published image the installed command runs by default and how to
  override it
- **AND** it states which architecture's image the publish scans do not cover
