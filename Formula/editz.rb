# Formula for the tap https://github.com/beprajwal/homebrew-tap (Formula/editz.rb), rendered by
# scripts/render-formula.sh from the validated binary tarballs (platforms that were not built and smoke-tested are
# left out of the rendered formula). Install: brew install beprajwal/tap/editz
# The tarballs hold a standalone (Nuitka) build: Python and every library are bundled, only ffmpeg comes from Homebrew.
class Editz < Formula
  desc "Agentic 360-degree footage to short-form vertical video pipeline"
  homepage "https://github.com/beprajwal/editz"
  version "0.5.0"
  license :cannot_represent

  on_macos do
    depends_on arch: :arm64
    on_arm do
      url "https://github.com/beprajwal/homebrew-tap/releases/download/editz-v0.5.0/editz-v0.5.0-macos-arm64.tar.gz"
      sha256 "613df9defac27aea5fe812b57fe223777b2ab8bfd0f329562d01029c698c28c5"
    end
  end

  on_linux do
    # A Linux arch without a validated binary in this release is refused by brew instead of installing nothing.
    on_arm do
      url "https://github.com/beprajwal/homebrew-tap/releases/download/editz-v0.5.0/editz-v0.5.0-linux-arm64.tar.gz"
      sha256 "39c9426d5cda256017579677c2eccd50bc86cfcec9f0d2e131320add8ce3a495"
    end
    on_intel do
      url "https://github.com/beprajwal/homebrew-tap/releases/download/editz-v0.5.0/editz-v0.5.0-linux-x86_64.tar.gz"
      sha256 "ddbdf392917c13a74da3f71320b0d1016d77189e1451bcdb5e816edf4c43567a"
    end
  end

  depends_on "ffmpeg"

  def install
    libexec.install Dir["*"]
    bin.install_symlink libexec/"editz-bin" => "editz"
  end

  def caveats
    on_macos do
      <<~EOS
        Burned-in text needs an ffmpeg with libass:
          brew install ffmpeg-full
        Stitching 360 footage runs the Insta360 SDK image (amd64) in a container:
          brew install container && softwareupdate --install-rosetta --agree-to-license
          (or use Docker Desktop / Colima / OrbStack: editz picks the runtime automatically)
        Build the image from your own Insta360 SDK download (proprietary, not shipped):
          editz build-image --vendor <dir>   # see scripts/vendor-sdks.sh in the editz repo
        Download fonts for text overlays: editz fonts sync
        Then run: editz doctor
      EOS
    end
    on_linux do
      <<~EOS
        Burned-in text needs an ffmpeg with libass (most distro builds have it).
        Stitching 360 footage runs the Insta360 SDK image (amd64) with docker or podman:
          sudo apt-get install docker.io   # or podman; add your user to the docker group
          arm64 hosts also need amd64 emulation: sudo apt-get install qemu-user-static
        Build the image from your own Insta360 SDK download: editz build-image --vendor <dir>
        Download fonts for text overlays: editz fonts sync
        Then run: editz doctor
      EOS
    end
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/editz --version")
    assert_match "ClipPlan", shell_output("#{bin}/editz schema plan")
  end
end
