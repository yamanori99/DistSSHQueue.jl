category: skip

- Test job trees that run `go` include a `Manifest.toml`. DistSSHRun refuses a project file with no Manifest. Those trees copy the DistSSHRun this process loaded as a relative `[sources]` path, not DistSSHRun 0.1.14 from General.
