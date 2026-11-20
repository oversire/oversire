# Client mode

Client mode lets a Mac show the data of another Mac. The other Mac is the home. This Mac needs no accounts and does not poll Plane, GitHub or CI.

## How to switch

1. Join a group. The home must run a daemon with the features `mirror` and `member-calls`.
2. Open Settings > Machines. Find the row "Mode".
3. Select "Client". Confirm the restart.
4. To go back, select "Full". A client can always go back.

## How it works

- One Mac in Full mode holds the lease `automations`. This Mac is the source. It sends its data to the mirror feed on the home daemon.
- A client reads the feed. It pulls at the start, on each `mirror` frame, and each minute.
- A click that changes data goes to the source app as a member call. The source runs it. The client then pulls the new data.
- The client keeps the last data in a cache. It shows this data in each state.

## What is shared

- Projects, items, pull requests, CI runs, activity and the catalog.
- The settings of the sections Projects, Repos, CI, Linking, Agents, AI jobs and Sessions. A change goes to the home. See `ClientSettings`.

Not shared: the accounts and the tokens of each Mac, the window state and the local preferences.

## The states of the link

| State | Meaning | Changes |
| --- | --- | --- |
| Waiting | The home has no data yet. | Off |
| Live | The home answers and the source is open. | On |
| Update needed | The feed has a newer version than this app reads. | On |
| Home offline | The WebSocket is down and the pull fails for 30 s. | Off |
| App closed | The home answers, but the OverSire app of the source is not open. | Off |
| No source | No Mac holds the lease `automations`. | Off |
| Moving | The home moved. The client reads from the new home. | Off |

A short drop of the network does not change the state. The state "Home offline" starts only after 30 s.

In each state the client shows the last data and the time of that data ("data from 14:02"). A control that needs the source is off and has a tooltip with the reason. Reads, navigation and the switch to Full mode stay on. A page shows a banner with the button "Try again".

Shared settings pages show the same banner. Their shared rows are off until the home is back.

## Home move

When the home moves to another machine, the new home starts with an empty feed and a new epoch. The source sends all its docs again. The client keeps the old data until the new feed is ready. During the move, the state is "Moving".

## Clients on the Machines page

The home knows its readers. The page Settings > Machines shows the chiplet CLIENT on each Mac that read the feed in the last 10 min. The page reads the head with `?peek=1`, so that the view of the page does not count as a reader.

## Log

Each change of the state writes one log line: `client link homeOffline since=<time>`.
