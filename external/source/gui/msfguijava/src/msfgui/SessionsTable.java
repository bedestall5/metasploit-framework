package msfgui;

import java.util.List;
import java.util.Map;
import javax.swing.table.*;

/**
 *
 * @author scriptjunkie
 */
public class SessionsTable extends AbstractTableModel {
	public static final int TITLE_INDEX = 0;
	public static final int ARTIST_INDEX = 1;
	public static final int ALBUM_INDEX = 2;
	public static final int HIDDEN_INDEX = 3;
	protected String[] columnNames;
	protected List sessions;

	public SessionsTable(List sessions) {
		//also have "info", "workspace", "target_host", "username", "exploit_uuid"
		this.columnNames = new String[]{"type","tunnel_local","tunnel_peer","via_exploit","via_payload","desc","uuid","platform"};
		this.sessions = sessions;
	}

	@Override
	public String getColumnName(int column) {
		return columnNames[column];
	}

	@Override
	public boolean isCellEditable(int row, int column) {
		return false;
	}

	@Override
	public Class getColumnClass(int column) {
		return String.class;
	}

	public Object getValueAt(int row, int column) {
		return ((Map) sessions.get(row)).get(columnNames[column]);
	}

	@Override
	public void setValueAt(Object value, int row, int column) {
	}

	public int getRowCount() {
		return sessions.size();
	}

	public int getColumnCount() {
		return columnNames.length;
	}

	public void updateSessions(List newSessions) {
		sessions = newSessions;
	}

	public List getSessionList() {
		return sessions;
	}
}
