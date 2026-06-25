# Fluid Simulator tasks

base_href := "/fluidSimulation/"
repo := "https://github.com/saif97/fluidSimulation.git"

# List available tasks
default:
    @just --list

# Run analyzer and tests
check:
    flutter analyze
    flutter test

# Serve locally in debug mode
run port="8080":
    flutter run -d web-server --web-port {{port}}

# Release build for GitHub Pages
build:
    flutter build web --release --base-href "{{base_href}}"

# Build and publish to GitHub Pages (gh-pages branch)
publish: check build
    cd build/web && \
    git init -b gh-pages && \
    git add -A && \
    git commit -m "Deploy $(git -C ../.. rev-parse --short HEAD)" && \
    git push -f {{repo}} gh-pages && \
    rm -rf .git
    @echo "Live at https://saif97.github.io/fluidSimulation/"
