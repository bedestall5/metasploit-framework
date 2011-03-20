package msfgui;

import java.awt.event.ActionEvent;
import java.awt.event.ActionListener;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.FileWriter;
import java.io.IOException;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.net.UnknownHostException;
import java.util.HashMap;
import java.util.LinkedList;
import java.util.List;
import java.util.Map;
import java.util.Map.Entry;
import java.util.regex.Pattern;
import javax.swing.JFileChooser;
import javax.swing.JMenu;
import javax.swing.JMenuItem;
import javax.swing.JOptionPane;
import org.jdesktop.application.Application;
import org.jdesktop.application.SingleFrameApplication;
import javax.xml.parsers.DocumentBuilderFactory;
import javax.xml.transform.TransformerFactory;
import javax.xml.transform.dom.DOMSource;
import javax.xml.transform.stream.StreamResult;
import org.w3c.dom.Document;

/**
 * The main class of the application. Handles global settings and system functions.
 * @author scriptjunkie
 */
public class MsfguiApp extends SingleFrameApplication {
	public static final int NUM_REMEMBERED_MODULES = 20;
	private static final Map propRoot;
	public static JFileChooser fileChooser;
	protected static Pattern backslash = Pattern.compile("\\\\");
	public static String workspace = "default";
	public static final String confFilename = System.getProperty("user.home")+File.separatorChar+".msf3"+File.separatorChar+"msfgui";
	public static MainFrame mainFrame;

	static{ //get saved properties file
		Map props;
		try{
			props = (Map)RpcConnection.parseVal(DocumentBuilderFactory.newInstance().newDocumentBuilder()
					.parse(new FileInputStream(confFilename)).getDocumentElement());
		} catch (Exception ex) { //if anything goes wrong, make new (IOException, SAXException, ParserConfigurationException, NullPointerException
			props = new HashMap();//ensure existence
		}
		propRoot = props;
		RpcConnection.disableDb = Boolean.TRUE.equals(propRoot.get("disableDb")); //restore this, since it can't be checked on connect
		if(propRoot.get("recentList") == null)
			propRoot.put("recentList", new LinkedList());
		Runtime.getRuntime().addShutdownHook(new Thread(){
			@Override
			public void run() {
				try {
					Document docElement = DocumentBuilderFactory.newInstance().newDocumentBuilder().newDocument();
					docElement.appendChild(RpcConnection.objectToNode(docElement, propRoot));
					TransformerFactory.newInstance().newTransformer().transform(
							new DOMSource(docElement), new StreamResult(new FileOutputStream(confFilename)));
				} catch (Exception ex) {
					//fail
					try{ //Problem saving conf file; we are closing here, so we shouldn't try to pop up a message box
						FileWriter fout = new FileWriter(confFilename+"ERROR.log", true);
						fout.write(java.util.Calendar.getInstance().getTime().toString());
						fout.write(" Error saving properties. Check "+confFilename+" file permissions.\n");
						fout.write(ex.toString()+"\n");
						fout.close();
					} catch (Exception exc) {
						 //epic fail
					}
				}
			}
		});
	}

	/**
	 * At startup create and show the main frame of the application.
	 */
	@Override protected void startup() {
		MsfguiLog.initDefaultLog();
		mainFrame = new MainFrame(this);
		show(mainFrame);
	}

	/**
	 * This method is to initialize the specified window by injecting resources.
	 * Windows shown in our application come fully initialized from the GUI
	 * builder, so this additional configuration is not needed.
	 */
	@Override protected void configureWindow(java.awt.Window root) {
	}

	/**
	 * A convenient static getter for the application instance.
	 * @return the instance of MsfguiApp
	 */
	public static MsfguiApp getApplication() {
		return Application.getInstance(MsfguiApp.class);
	}

	/**
	 * Main method launching the application.
	 */
	public static void main(String[] args) {
		launch(MsfguiApp.class, args);
	}

	/** Application helper to launch msfrpcd or msfencode, etc. */
	public static Process startMsfProc(List command) throws MsfException{
		return startMsfProc((String[])command.toArray(new String[command.size()]));
	}
	/** Application helper to launch msfrpcd or msfencode, etc. */
	public static Process startMsfProc(String[] args) throws MsfException {
		String msfCommand = args[0];
		String prefix;
		try{
			prefix = getPropertiesNode().get("commandPrefix").toString();
		}catch(Exception ex){
			prefix = "";
		}
		Process proc;
		String[] winArgs = null;
		try {
			args[0] = prefix + msfCommand;
			proc = Runtime.getRuntime().exec(args);
		} catch (Exception ex1) {
			try {
				proc = Runtime.getRuntime().exec(args);
			} catch (IOException ex2) {
				try {
					args[0] = getMsfRoot() + "/" + msfCommand;
					proc = Runtime.getRuntime().exec(args);
				} catch (IOException ex3) {
					try {
						winArgs = new String[args.length + 3];
						System.arraycopy(args, 0, winArgs, 3, args.length);
						winArgs[0] = "cmd";
						winArgs[1] = "/c";
						winArgs[2] = "ruby.exe";
						winArgs[3] = msfCommand;
						proc = Runtime.getRuntime().exec(winArgs);
					} catch (IOException ex4){
						try{
							if (msfCommand.equals("msfencode"))
								winArgs[2] = "ruby.exe";
							else
								winArgs[2] = "rubyw.exe";
							winArgs[3] = getMsfRoot() + "/"  + msfCommand;
							proc = Runtime.getRuntime().exec(winArgs);
						} catch (IOException ex5) {
							try {
								File dir = new File(prefix);
								winArgs[3] = msfCommand;
								proc = Runtime.getRuntime().exec(winArgs, null, dir);
							} catch (IOException ex7) {
								throw new MsfException("Executable not found for "+msfCommand);
							}
						}
					}
				}
			}
		}
		return proc;
	}

	/** Get root node of xml saved options file */
	public static Map getPropertiesNode(){
		return propRoot;
	}
	/**
	 * Finds the path to the root of the metasploit tree (the msf3 folder this jar is being run out of)
	 * @return A File object pointing to the directory at the root of the metasploit tre
	 * @throws MsfException if this jar file has been moved or the containing directory structure has been moved.
	 */
	public static File getMsfRoot() throws MsfException{
		File f = new File(MsfguiApp.class.getProtectionDomain().getCodeSource().getLocation().getPath());
		File parent = f.getParentFile();
		File grandparent = parent.getParentFile();
		if(f.getName().equals("msfgui.jar") && parent.getName().equals("gui") &&  grandparent.getName().equals("data"))
			return grandparent.getParentFile();
		throw new MsfException("Cannot find path.");
	}

	/** Adds a module run to the recent modules list */
	public static void addRecentModule(final List args, final RpcConnection rpcConn, final MainFrame mf) {
		addRecentModule(args, rpcConn, mf, true);
	}
	public static void addRecentModule(final List args, final RpcConnection rpcConn, final MainFrame mf, boolean ignoreDups) {
		final JMenu recentMenu = mf.recentMenu;
		List recentList = (List)propRoot.get("recentList");
		if(recentList.contains(args)){
			if(ignoreDups)
				return;
		}else{
			recentList.add(args);
		}
		Map hash = (Map)args.get(2);
		StringBuilder name = new StringBuilder(args.get(0) + " " + args.get(1));
		for(Object ento : hash.entrySet()){
			Entry ent = (Entry)ento;
			String propName = ent.getKey().toString();
			if(propName.endsWith("HOST") || propName.endsWith("PORT") || propName.equals("PAYLOAD"))
				name.append(" ").append(propName).append("-").append(ent.getValue());
		}
		final JMenuItem item = new JMenuItem(name.toString());
		item.addActionListener(new ActionListener() {
			public void actionPerformed(ActionEvent e) {
				new ModulePopup(rpcConn, args.toArray(), mf).setVisible(true);
				recentMenu.remove(item);
				recentMenu.add(item);
				List recentList = (List)propRoot.get("recentList");
				for(int i = 0; i < recentList.size(); i++){
					if(recentList.get(i).equals(args)){
						recentList.add(recentList.remove(i));
						break;
					}
				}
			}
		});
		recentMenu.add(item);
		recentMenu.setEnabled(true);
		if(recentMenu.getItemCount() > NUM_REMEMBERED_MODULES)
			recentMenu.remove(0);
		if(recentList.size() > NUM_REMEMBERED_MODULES)
			recentList.remove(0);
	}
	public static void addRecentModules(final RpcConnection rpcConn, final MainFrame mf) {
		List recentList = (List)propRoot.get("recentList");
		for(Object item : recentList)
			addRecentModule((List)item, rpcConn, mf, false);
	}

	/** Clear history of run modules */
	public static void clearHistory(JMenu recentMenu){
		((List)propRoot.get("recentList")).clear();
		recentMenu.removeAll();
		recentMenu.setEnabled(false);
	}

	/** Gets a temp file from system */
	public static String getTempFilename(String prefix, String suffix) {
		try{
			final File temp = File.createTempFile(prefix, suffix);
			String path = temp.getAbsolutePath();
			temp.delete();
			return path;
		}catch(IOException ex){
			JOptionPane.showMessageDialog(null, "Cannot create temp file. This is a bad and unexpected error. What is wrong with your system?!");
			return null;
		}
	}

	/** Gets a temp folder from system */
	public static String getTempFolder() {
		try{
			final File temp = File.createTempFile("abcde", ".bcde");
			String path = temp.getParentFile().getAbsolutePath();
			temp.delete();
			return path;
		}catch(IOException ex){
			JOptionPane.showMessageDialog(null, "Cannot create temp file. This is a bad and unexpected error. What is wrong with your system?!");
			return null;
		}
	}

	/** Returns the likely local IP address for talking to the world */
	public static String getLocalIp(){
		try{
			DatagramSocket socket = new DatagramSocket();
			socket.connect(InetAddress.getByName("1.2.3.4"),1234);
			socket.getLocalAddress();
			String answer = socket.getLocalAddress().getHostAddress();
			socket.close();
			return answer;
		} catch(IOException ioe){
			try{
				return InetAddress.getLocalHost().getHostAddress();
			}catch (UnknownHostException uhe){
				return "127.0.0.1";
			}
		}
	}

	public static String cleanBackslashes(String input){
		return backslash.matcher(input).replaceAll("/");
	}
	public static String doubleBackslashes(String input){
		return backslash.matcher(input).replaceAll("\\\\\\\\");
	}
}
