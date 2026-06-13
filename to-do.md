# To-Do List

`Views/Sidebar/NavigatorModel.swift` is the navigator's tree state that survives the panel closing. Importantly, it includes info on expanded folders. But in reality, closeing the sidebar (i.e., toggling active panel off and thereby having no active panels) destroyes the state, possibly because the sidebar itself gets torn down. Perhaps some of the tree state, mostly expanded folders and context folder designation, need to live at the `ContentView` level.
