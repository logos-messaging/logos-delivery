
## Has been compiled with Qt 5.15.2

## If change the main.qml, the qmake should be called
## This may be needed in Ubuntu: sudo apt install qtdeclarative5-dev qtquickcontrols2-5-dev

CXX = g++
CXXFLAGS = -g3 -fpermissive -fPIC `pkg-config --cflags Qt5Core Qt5Gui Qt5Qml Qt5Quick`
LDFLAGS = `pkg-config --libs Qt5Core Qt5Gui Qt5Qml Qt5Quick` -llogosdelivery -L../../build/
MOC = moc

TARGET = main-qt
SRC = main_qt.cpp
MOC_SRC = waku_handler.moc.cpp
HEADERS = waku_handler.h

all: $(TARGET)

$(MOC_SRC): $(HEADERS)
	$(MOC) $< -o $@

$(TARGET): $(SRC) $(MOC_SRC)
	$(CXX) $(CXXFLAGS) -o $(TARGET) $(SRC) $(MOC_SRC) $(LDFLAGS)

clean:
	rm -f $(TARGET) $(MOC_SRC)
