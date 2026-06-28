- Drawer behavior:
    - A drawer will appear when I double click on an event. Currently, a huge drawer will be drawn out from the right
    - There is a current problem that, if I do not move the main calendar canvas, if the event is towards the right hand side of the screen, then the drawer will occlude that event; If I do shift the main calendar canvas to the left, then if the event is on the left hand side of the canvas, the event will go out-of-screen
    - The proposed solution is that, we should understand which event that we are clicking on, and the goal is to shift the main canvas to a point where the event is horizontally centered in the remaining space.
    - The computation is the following:
        - Say the screen width is X
        - Say the drawer's width is D, D < X
        - When the drawer is drawn out, the left-hand-side masked-out space is of width X - D
        - Say the event is originally horizontally located at U < X (suppose U is the left-hand-side)
        - The goal would be shifting the main canvas left such that the new event location U' is in the center of X - D, meaning (X - D) / 2 == U'
        - Therefore, the left shift delta of the main canvas is U - (X - D) / 2
            - We do want to cap the shift delta to be above zero, because we do not want the main canvas to shift rightwards
            - Meaning that is an event is already placed towards the left hand side of the screen and even to the left of the middle point in the free area, we do not need to move the canvas.
    - A few note:
        - When we resize the drawer, the main canvas should be responsive and move accordingly.

- [x] Scroll-up/down behavior in monthly view
    - When we scroll up or down in the monthly view, we should be able to go to previous month and next month
    - The current behavior is that in the monthly view, we cannot scroll, neither left/right nor up/down
    - The scroll behavior should be the following:
        - Treat each month as if they are vertical pages
        - We are swiping across pages like they are iPhone's homescreen, just put vertical
        - When we swipe up (from current month to next month), the action should be:
            - The daily timeline view first fades out (without distortion)
            - The next month's tracks come up from the bottom
            - When it gets closer to the top, the current month's track (originally stayed on the top) will move upwards and disappear out at the top
            - And the next month's tracks take the place of the current month's track
            - And the next month's daily view starts appearing (fade-in, without distortion)
        - When we swipe down (from current month to prev month), the action would be the mostly the reverted
            - The daily timeline view first fades out
            - The current month's tracks start moving downwards
            - While that is happening, the previous month's tracks comes down from the top
            - The previous month's tracks stopped at taking place of the current month's tracks
            - The current month's tracks keeps moving down and go out of the screen
            - The previous month's daily view starts appearing (fade-in)

- [x] The minimum height of each hour in the weekly view can be smaller
    - Currently I think there is a 50px minimum; I think it could be as low as 35px.

- [x] rework the month border in weekly view
    - in weekly view, we will draw a month border to the left of 1st day or to the right of the last day of the month
    - Currently that line, let's call monthly border, has multiple problems
        - First, it will appear over the gap on the left hand side; because it's very tall, it will be visible in collision with the track name editor and even the month name
        - Second, its height goes over on the top by a few pixels, extending beyond the top of the tracks
        - Third, it is too thick
    - To make it better:
        - We only show that line when it is horizontally within range of the month (day 1 to end), not on the left
        - Make it thinner
        - There should be two segments for this line, one strictly on the track band (the height of 4 tracks), the other one strictly on the daily detail view; the two segments should be separated by the week day name row

- [x] The hourly event's text displaying scheme is still not working.
    - I guess you had some different way of rendering recurring and normal events? The normal events would have their texts rendered correctly: when the height of the event is small, we only show the event title in one line and no display of time to save space. But for recurring events I still see the time displayed right there and the single line of event name got cut off horizontally.

- [x] There is one more timed event's text displaying scheme need fixing:
    - When the drawer is opened, there is a highlighted timed event shown above the mask
    - The text of this highlighted timed event should be displayed the same way as its original; there should be also small symbols like "recurrent", "AI", or "promoted" rendered above it.

- [x] In the event drawer after clicking on a recurrent event, there is a grouped tab on "Series" or "This Event". Following that "This Event", there should be a date shown, so it should read "This Event - June 6"
    - Also for the event drawer of recurrent events, right below the title, there is time shown. Currently it is showing "The date where this event is initially happening" and then the time ranges.
    - I would like that to show "This Event: (the date of currently selected occurrence)"
    - And another line shows "Initial Event Date: (the date of the initial event of this series of recurrent events)"

- TODO List in Calendar
    - Let's forget about a centralized todo viewer; but rather a contextualized todo viewer in a monthly view or a weekly view.
    - There turns out to be an empty space in monthly/weekly view, that sits right to the left of the daily
