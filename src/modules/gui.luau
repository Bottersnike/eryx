export type App = {
	run: (self: App) -> (),
	quit: (self: App) -> (),
}

export type Window = {
	minimumSize: (self: Window, width: number, height: number) -> (),
	setTitle: (self: Window, title: string) -> (),
	setLayout: (self: Window, layout: Layout) -> (),
	setStatusBar: (self: Window, statusBar: StatusBar) -> (),
	setMenuBar: (self: Window, menuBar: MenuBar) -> (),
	onClose: (self: Window, callback: (event: { canVeto: boolean, closed: boolean }) -> ()) -> (),
	show: (self: Window) -> (),
	close: (self: Window) -> (),
}

export type Dialog = {
	minimumSize: (self: Dialog, width: number, height: number) -> (),
	setTitle: (self: Dialog, title: string) -> (),
	setLayout: (self: Dialog, layout: Layout) -> (),
	onClose: (self: Dialog, callback: (event: { canVeto: boolean, closed: boolean }) -> ()) -> (),
	show: (self: Dialog) -> (),
	showModal: (self: Dialog) -> number?,
	close: (self: Dialog) -> (),
}

export type LayoutChildOptions = {
	expand: boolean?,
}

export type Layout = {
	add: (self: Layout, child: Layout | Spacer | Widget, options: LayoutChildOptions?) -> (),
	padding: (self: Layout, value: number) -> (),
	gap: (self: Layout, value: number) -> (),
}

export type Spacer = {}

export type Widget = {
	enabled: (self: Widget, value: boolean?) -> boolean?,
	text: (self: Widget, value: string?) -> string?,
}

export type Label = Widget

export type Button = Widget & {
	onClick: (self: Button, callback: () -> ()) -> (),
	setIcon: (self: Button, bitmap: Bitmap) -> (),
}

export type ToggleButton = Widget & {
	checked: (self: ToggleButton, value: boolean?) -> boolean?,
	onClick: (self: ToggleButton, callback: () -> ()) -> (),
	onChange: (self: ToggleButton, callback: (checked: boolean) -> ()) -> (),
}

export type ToolBar = Widget & {
	add: (self: ToolBar, item: Action?) -> (),
}

export type TextBox = Widget & {
	placeholder: (self: TextBox, value: string) -> (),
	readOnly: (self: TextBox, value: boolean?) -> boolean?,
	password: (self: TextBox, value: boolean?) -> boolean?,
	append: (self: TextBox, value: string) -> (),
	onChange: (self: TextBox, callback: (text: string) -> ()) -> (),
	onSubmit: (self: TextBox, callback: (text: string) -> ()) -> (),
}

export type TextArea = Widget & {
	placeholder: (self: TextArea, value: string) -> (),
	readOnly: (self: TextArea, value: boolean?) -> boolean?,
	append: (self: TextArea, value: string) -> (),
	onChange: (self: TextArea, callback: (text: string) -> ()) -> (),
}

export type SearchBox = Widget & {
	placeholder: (self: SearchBox, value: string) -> (),
	onChange: (self: SearchBox, callback: (text: string) -> ()) -> (),
	onSubmit: (self: SearchBox, callback: (text: string) -> ()) -> (),
}

export type CheckBox = Widget & {
	checked: (self: CheckBox, value: boolean?) -> boolean?,
	onChange: (self: CheckBox, callback: (checked: boolean) -> ()) -> (),
}

export type RadioButton = Widget & {
	checked: (self: RadioButton, value: boolean?) -> boolean?,
	onChange: (self: RadioButton, callback: (checked: boolean) -> ()) -> (),
}

export type DatePicker = Widget & {
	onChange: (self: DatePicker, callback: (value: string) -> ()) -> (),
}

export type Hyperlink = Widget & {
	url: (self: Hyperlink, value: string?) -> string?,
	onClick: (self: Hyperlink, callback: () -> ()) -> (),
}

export type Choice = Widget & {
	setItems: (self: Choice, items: { string }) -> (),
	selected: (self: Choice, index: number?) -> number?,
	onChange: (self: Choice, callback: (value: string) -> ()) -> (),
}

export type ComboBox = Widget & {
	setItems: (self: ComboBox, items: { string }) -> (),
	selected: (self: ComboBox, index: number?) -> number?,
	onChange: (self: ComboBox, callback: (value: string) -> ()) -> (),
}

export type ListBox = Widget & {
	setItems: (self: ListBox, items: { string }) -> (),
	selected: (self: ListBox, index: number?) -> number?,
	onChange: (self: ListBox, callback: (value: string) -> ()) -> (),
}

export type TreeNode = {
	label: string,
	children: { TreeNode }?,
}

export type TreeView = Widget & {
	setNodes: (self: TreeView, nodes: { TreeNode }) -> (),
	onSelect: (self: TreeView, callback: (label: string) -> ()) -> (),
}

export type ProgressBar = Widget & {
	range: (self: ProgressBar, value: number) -> (),
	value: (self: ProgressBar, value: number?) -> number?,
	pulse: (self: ProgressBar) -> (),
}

export type Slider = Widget & {
	limits: (self: Slider, min: number, max: number) -> (),
	value: (self: Slider, value: number?) -> number?,
	onChange: (self: Slider, callback: (value: number) -> ()) -> (),
}

export type SpinBox = Widget & {
	limits: (self: SpinBox, min: number, max: number) -> (),
	value: (self: SpinBox, value: number?) -> number?,
	onChange: (self: SpinBox, callback: (value: number) -> ()) -> (),
}

export type Tabs = Widget & {
	add: (self: Tabs, title: string, child: Layout | Spacer | Widget) -> (),
	selected: (self: Tabs, index: number?) -> number?,
	onSelect: (self: Tabs, callback: (index: number) -> ()) -> (),
}

export type TableColumn = {
	key: string,
	title: string,
	width: number?,
	expand: boolean?,
}

export type TableRow = { [string]: string | number | boolean }

export type TableView = Widget & {
	setColumns: (self: TableView, columns: { TableColumn }) -> (),
	setRows: (self: TableView, rows: { TableRow }) -> (),
	setFilter: (self: TableView, filter: string) -> (),
}

export type ListView = Widget & {
	setColumns: (self: ListView, columns: { TableColumn }) -> (),
	setRows: (self: ListView, rows: { TableRow }) -> (),
	setFilter: (self: ListView, filter: string) -> (),
	selected: (self: ListView, index: number?) -> number?,
	onSelect: (self: ListView, callback: (index: number) -> ()) -> (),
}

export type Panel = Widget & {
	add: (self: Panel, child: Layout | Spacer | Widget) -> (),
}

export type ScrollArea = Widget & {
	add: (self: ScrollArea, child: Layout | Spacer | Widget) -> (),
}

export type GroupBox = Widget & {
	add: (self: GroupBox, child: Layout | Spacer | Widget) -> (),
}

export type StaticLine = Widget

export type InfoBar = Widget & {
	showMessage: (self: InfoBar, message: string, kind: "info" | "warning" | "error"?) -> (),
	dismiss: (self: InfoBar) -> (),
}

export type Splitter = Widget & {
	setPanes: (self: Splitter, first: Layout | Spacer | Widget, second: Layout | Spacer | Widget) -> (),
	position: (self: Splitter, value: number?) -> number?,
}

export type StatusBar = {
	setText: (self: StatusBar, text: string, field: number?) -> (),
	setFields: (self: StatusBar, widths: { number }) -> (),
}

export type Menu = {
	add: (self: Menu, action: Action?) -> (),
	addSeparator: (self: Menu) -> (),
}

export type MenuBar = {
	add: (self: MenuBar, menu: Menu) -> (),
}

export type Action = {}

export type Bitmap = {}

export type FileDialogOptions = {
	title: string?,
	filter: string?,
}

export type DirectoryDialogOptions = {
	title: string?,
}

export type MessageBoxOptions = {
	title: string?,
	message: string?,
	kind: "info" | "warning" | "error"?,
}

export type TextEntryDialogOptions = {
	title: string?,
	message: string?,
	value: string?,
}

export type NumberEntryDialogOptions = {
	title: string?,
	message: string?,
	value: number?,
	min: number?,
	max: number?,
}

export type ChoiceDialogOptions = {
	title: string?,
	message: string?,
	choices: { string },
}

export type AboutDialogOptions = {
	name: string?,
	version: string?,
	description: string?,
}

export type ProgressDialogOptions = {
	title: string?,
	message: string?,
	value: number?,
	max: number?,
}

local gui = {}

function gui.App(): App
	return nil :: any
end

function gui.Window(title: string, width: number, height: number): Window
	return nil :: any
end

function gui.Dialog(title: string, width: number, height: number): Dialog
	return nil :: any
end

function gui.VBox(): Layout
	return nil :: any
end

function gui.HBox(): Layout
	return nil :: any
end

function gui.Grid(columns: number?): Layout
	return nil :: any
end

function gui.Form(): Layout
	return nil :: any
end

function gui.Spacer(size: number?): Spacer
	return nil :: any
end

function gui.Label(text: string?): Label
	return nil :: any
end

function gui.Button(text: string?): Button
	return nil :: any
end

function gui.ToggleButton(text: string?): ToggleButton
	return nil :: any
end

function gui.ToolBar(): ToolBar
	return nil :: any
end

function gui.TextBox(text: string?): TextBox
	return nil :: any
end

function gui.TextArea(text: string?): TextArea
	return nil :: any
end

function gui.SearchBox(text: string?): SearchBox
	return nil :: any
end

function gui.CheckBox(text: string?): CheckBox
	return nil :: any
end

function gui.RadioButton(text: string?): RadioButton
	return nil :: any
end

function gui.DatePicker(value: string?): DatePicker
	return nil :: any
end

function gui.Hyperlink(text: string?, url: string?): Hyperlink
	return nil :: any
end

function gui.Choice(text: string?): Choice
	return nil :: any
end

function gui.ComboBox(text: string?): ComboBox
	return nil :: any
end

function gui.ListBox(): ListBox
	return nil :: any
end

function gui.TreeView(): TreeView
	return nil :: any
end

function gui.Slider(value: number?): Slider
	return nil :: any
end

function gui.SpinBox(value: number?): SpinBox
	return nil :: any
end

function gui.ProgressBar(range: number?): ProgressBar
	return nil :: any
end

function gui.Tabs(): Tabs
	return nil :: any
end

function gui.TableView(): TableView
	return nil :: any
end

function gui.ListView(): ListView
	return nil :: any
end

function gui.Panel(): Panel
	return nil :: any
end

function gui.ScrollArea(): ScrollArea
	return nil :: any
end

function gui.GroupBox(text: string?): GroupBox
	return nil :: any
end

function gui.StaticLine(): StaticLine
	return nil :: any
end

function gui.InfoBar(): InfoBar
	return nil :: any
end

function gui.HSplitter(position: number?): Splitter
	return nil :: any
end

function gui.VSplitter(position: number?): Splitter
	return nil :: any
end

function gui.StatusBar(text: string?): StatusBar
	return nil :: any
end

function gui.Menu(title: string): Menu
	return nil :: any
end

function gui.MenuBar(children: { Menu }?): MenuBar
	return nil :: any
end

function gui.Action(label: string, callback: (() -> ())?): Action
	return nil :: any
end

function gui.bitmap(image: any): Bitmap
	return nil :: any
end

function gui.openFileDialog(options: FileDialogOptions): string?
	return nil :: any
end

function gui.saveFileDialog(options: FileDialogOptions): string?
	return nil :: any
end

function gui.openDirectoryDialog(options: DirectoryDialogOptions): string?
	return nil :: any
end

function gui.messageBox(options: MessageBoxOptions) end

function gui.textEntryDialog(options: TextEntryDialogOptions): string?
	return nil :: any
end

function gui.numberEntryDialog(options: NumberEntryDialogOptions): number?
	return nil :: any
end

function gui.choiceDialog(options: ChoiceDialogOptions): string?
	return nil :: any
end

function gui.colourDialog(): string?
	return nil :: any
end

function gui.fontDialog(): { face: string, size: number, bold: boolean, italic: boolean }?
	return nil :: any
end

function gui.aboutDialog(options: AboutDialogOptions) end

function gui.progressDialog(options: ProgressDialogOptions): boolean
	return nil :: any
end

function gui.setClipboardText(text: string) end

function gui.getClipboardText(): string
	return nil :: any
end

return gui
