package msfgui;

import java.awt.Component;
import java.awt.HeadlessException;
import java.awt.Point;
import java.awt.Window;
import java.awt.event.ActionEvent;
import java.awt.event.ActionListener;
import java.awt.event.FocusEvent;
import java.awt.event.FocusListener;
import java.awt.event.MouseAdapter;
import java.awt.event.MouseEvent;
import java.awt.event.MouseMotionAdapter;
import java.awt.event.WindowEvent;
import java.awt.event.WindowFocusListener;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;
import javax.swing.JFrame;
import javax.swing.JLabel;
import javax.swing.JMenuItem;
import javax.swing.JPopupMenu;
import javax.swing.JTabbedPane;
import javax.swing.JWindow;
import javax.swing.event.ChangeEvent;
import javax.swing.event.ChangeListener;

/**
 * An extension of the JTabbedPane that supports dragging tabs into a new order
 * or even into and out of new windows.
 *
 * @author scriptjunkie
 */
public class DraggableTabbedPane extends JTabbedPane{
	private static Set panes = new HashSet();
	private boolean dragging = false;
	private int draggedTabIndex = 0;
	private Map focusListeners = new HashMap();
	private static FocusListener lastFocusListener = null;
	private static JWindow window;
	private final ChangeListener chListener;
	static{
		//Set up placeholder window. (Shows when moving tabs)
		window = new JWindow();
		window.getContentPane().add(new JLabel("Moving", JLabel.CENTER), java.awt.BorderLayout.CENTER);
		window.setSize(300, 300);
	}

	/**
	 * Finds the parent tab of the component given in c.
	 * @param c  The component whose tab is to be obtained
	 */
	public static DraggableTabbedPane getTabPane(Component c){
		Component subParent = c, par;
		for(par = subParent.getParent(); !(par instanceof DraggableTabbedPane); par = par.getParent())
			subParent = par;
		return  (DraggableTabbedPane)par;
	}

	/**
	 * Finds the parent tab of the component given in c, and dis/enables it.
	 * @param c  The component whose tab is to be dis/enabled
	 * @param enabled  The new enabled state of the tab
	 */
	public static void setTabComponentEnabled(Component c, boolean enabled){
		Component subParent = c, par;
		for(par = subParent.getParent(); !(par instanceof DraggableTabbedPane) && par != null; par = par.getParent())
			subParent = par;
		if(par == null)
			throw new MsfException("Error in DraggableTabbedPane.show; no parent is a DraggableTabbedPane!");
		DraggableTabbedPane pane = (DraggableTabbedPane)par;
		for(int i = 0; i < pane.getTabCount(); i++)
			if(pane.getComponentAt(i).equals(subParent))
				pane.setEnabledAt(i, enabled);
	}

	/**
	 * Adds a listener which will be notified when the given tab receives or loses focus
	 *
	 * @param listener
	 */
	public void setTabFocusListener(int tabIndex, FocusListener listener){
		focusListeners.put(getComponentAt(tabIndex), listener);
	}

	/**
	 * Moves the given tab to the destination DraggableTabbedPane.
	 *
	 * @param sourceIndex
	 * @param destinationPane
	 */
	public void moveTabTo(int sourceIndex, DraggableTabbedPane destinationPane){
		moveTabTo(sourceIndex, destinationPane, destinationPane.getTabCount());
	}

	/**
	 * Moves the given tab to the destination DraggableTabbedPane at the destination index
	 *
	 * @param sourceIndex
	 * @param destinationPane
	 * @param destinationIndex
	 */
	public void moveTabTo(int sourceIndex, DraggableTabbedPane destinationPane, int destinationIndex){
		//First save tab information
		Component comp = getComponentAt(sourceIndex);
		String title = getTitleAt(sourceIndex);
		boolean enabled = isEnabledAt(draggedTabIndex);

		//Then move tab and restore information
		removeTabAt(sourceIndex);
		destinationPane.insertTab(title, null, comp, null, destinationIndex);
		destinationPane.setEnabledAt(destinationIndex, enabled);
		destinationPane.setSelectedIndex(destinationIndex);
		destinationPane.focusListeners.put(comp, focusListeners.get(comp));

		//If we got rid of the last tab, close this window, unless it's the main window
		JFrame rent = (JFrame)getTopLevelAncestor();
		if(getTabCount() < 1 && rent != MsfguiApp.mainFrame.getFrame()){
			rent.setVisible(false);
			rent.dispose();
			panes.remove(DraggableTabbedPane.this);
		}
	}

	/**
	 * Finds the parent tab of the component given in c, and makes it visible.
	 * @param c  The component whose tab is to be made visible
	 */
	public static void show(Component c){
		//Find containing tab pane
		Component subParent = c, par;
		for(par = subParent.getParent(); !(par instanceof DraggableTabbedPane) && par != null; par = par.getParent())
			subParent = par;
		if(par == null)
			throw new MsfException("Error in DraggableTabbedPane.show; no parent is a DraggableTabbedPane!");
		DraggableTabbedPane pane = (DraggableTabbedPane)par;
		//Show this tab
		for(int i = 0; i < pane.getTabCount(); i++)
			if(pane.getComponentAt(i).equals(subParent))
				pane.setSelectedIndex(i);
		lastFocusListener = (FocusListener)pane.focusListeners.get(pane.getSelectedComponent());
		//Also make containing window show up
		for(par = pane.getParent(); !(par instanceof Window); par = par.getParent())
			;
		((Window)par).setVisible(true);
	}

	/**
	 * Tells this DraggableTabbedPane to listen for focus events on the parent window.
	 */
	public void addWindowFocusListener(){
		Window win = (Window)getTopLevelAncestor();
		//Notify on focus changes
		win.addWindowFocusListener(new WindowFocusListener(){
			public void windowGainedFocus(WindowEvent e) {
				chListener.stateChanged(new ChangeEvent(getSelectedComponent()));
			}
			public void windowLostFocus(WindowEvent e) {
			}
		});
	}

	/**
	 * Default constructor of DraggableTabbedPane.
	 */
	public DraggableTabbedPane() {
		//Set up right-click menu
		final JPopupMenu tabPopupMenu = new JPopupMenu();
		JMenuItem closeTabItem = new JMenuItem("Close this tab");
		closeTabItem.addActionListener(new ActionListener() {
			public void actionPerformed(ActionEvent e) {
				int indx = getSelectedIndex();
				if(indx != -1){
					JFrame newFrame = moveTabToNewFrame(indx,0,0);
					newFrame.setVisible(false);
					newFrame.dispose();
				}
			}
		});
		tabPopupMenu.add(closeTabItem);
		addMouseListener( new PopupMouseListener() {
			public void showPopup(MouseEvent e) {
				tabPopupMenu.show(DraggableTabbedPane.this, e.getX(), e.getY() );
			}
		});
		//Set up dragging listener
		addMouseMotionListener(new MouseMotionAdapter() {
			public void mouseDragged(MouseEvent e) {
				if (!dragging) {
					// Gets the tab index based on the mouse position
					int tabNumber = getUI().tabForCoordinate(DraggableTabbedPane.this, e.getX(), e.getY());
					if (tabNumber < 0)
						return;
					draggedTabIndex = tabNumber;
					dragging = true;
					window.setVisible(true);
				} else {
					window.setLocation(e.getXOnScreen(), e.getYOnScreen());
				}
				super.mouseDragged(e);
			}
		});
		//Set up tab change focus listener
		chListener = new ChangeListener() {
			public void stateChanged(ChangeEvent e) {
				FocusEvent event = new FocusEvent((Component)e.getSource(), getSelectedIndex());
				FocusListener listener = (FocusListener)focusListeners.get(getSelectedComponent());
				//If focus has been lost, trigger lost focus event
				if(lastFocusListener != null && lastFocusListener != listener)
					lastFocusListener.focusLost(event);
				//If we got focus, trigger gained focus event
				if(listener != null && lastFocusListener != listener){ // If we have a new tab
					listener.focusGained(event);
					lastFocusListener = listener;
				}
			}
		};
		this.addChangeListener(chListener);

		//Set up drop handler
		addMouseListener(new MouseAdapter() {
			public void mouseReleased(MouseEvent e) {
				if (!dragging)
					return;
				//We are done dragging
				dragging = false;
				window.setVisible(false);
				boolean moved = false;

				//Find out what pane this tab has been dragged to.
				for(Object tabo : panes){
					DraggableTabbedPane pane = (DraggableTabbedPane)tabo;
					try{
						Point ptabo = (pane).getLocationOnScreen();
						int x = e.getXOnScreen() - ptabo.x;
						int y = e.getYOnScreen() - ptabo.y;
						int tabNumber = pane.getUI().tabForCoordinate(pane, x, y);

						//If it's not on one of the tabs, but it's still in the tab bar, make a new tab
						if (tabNumber < 0 && pane.getBounds().contains(x, y))
							tabNumber = pane.getTabCount() - 1;

						//We found it!
						if (tabNumber >= 0) {
							moveTabTo(draggedTabIndex, pane, tabNumber);
							MsfguiApp.getPropertiesNode().put("tabWindowPreference", "tab"); //guess we like tabs
							return;
						}
					}catch(java.awt.IllegalComponentStateException icse){
					}// This is fired for non-visible windows. Can be safely ignored
				}
				//Not found. Must create new frame
				moveTabToNewFrame(draggedTabIndex,e.getXOnScreen(),e.getYOnScreen());
			}
		});
		panes.add(this);
	}

	/**
	 * Creates a new frame, and places the given tab in it
	 */
	private MsfFrame moveTabToNewFrame(int tabNumber, int x, int y) throws HeadlessException {
		MsfguiApp.getPropertiesNode().put("tabWindowPreference", "window"); //guess we like new windows
		final MsfFrame newFrame = new MsfFrame("Msfgui");
		newFrame.setSize(DraggableTabbedPane.this.getSize());
		newFrame.setLocation(x, y);
		//Make tabs to go in the frame
		final DraggableTabbedPane tabs = new DraggableTabbedPane();
		moveTabTo(tabNumber, tabs, 0);
		newFrame.add(tabs);
		newFrame.setVisible(true);
		//Clean up on exit
		newFrame.addWindowListener(new java.awt.event.WindowAdapter() {
			public void windowClosing(java.awt.event.WindowEvent evt) {
				panes.remove(tabs);
				if (panes.size() < 1)
					System.exit(0);
			}
		});
		tabs.addWindowFocusListener();
		return newFrame;
	}
}
