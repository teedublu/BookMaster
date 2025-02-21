if __name__ == "__main__":
    import tkinter as tk
    from ui.main_window import MainWindow

    root = tk.Tk()
    app = MainWindow(root)
    root.mainloop()