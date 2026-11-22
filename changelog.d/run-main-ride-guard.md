category: added

- Guard `submit ride` and `execute_kwargs` for `:ride` jobs when DistSSHRun on `main` no longer defines `parse_ride_args` (ride removed in Run #529). Enqueue still records `:ride` rows from older clients until a full Queue ride removal lands.
