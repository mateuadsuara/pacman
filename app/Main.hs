{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}

module Main where

import Brick
import Brick.Widgets.Center
import Brick.Widgets.Border
import Brick.Widgets.Border.Style
import Brick.BChan (newBChan, writeBChan)

import Graphics.Vty.Attributes
import Graphics.Vty.Input
import qualified Graphics.Vty as V

import Control.Lens
import Control.Monad
import Control.Monad.State
import Control.Monad.IO.Class

import Control.Concurrent (threadDelay, forkIO)

import qualified Data.Map as M

type NameData = ()
data EventData = Tick

type Row = Int
type Column = Int
type Width = Int
type Height = Int

type Position = (Row, Column)

up :: Position -> Position
up p = p & _1 %~ subtract 1

down :: Position -> Position
down p = p & _1 %~ (+1)

left :: Position -> Position
left p = p & _2 %~ subtract 1

right :: Position -> Position
right p = p & _2 %~ (+1)

type DashBoardSize = (Width, Height)
data BoardCell = Space | Brick | Pacman | Ghost deriving (Show, Eq)
type Board = M.Map Position BoardCell
data Movement = MoveLeft | MoveRight | MoveUp | MoveDown | Stop deriving Show
type Ghosts = [Character]
type Strategy = ContextData -> Character -> Character

instance Show Strategy where
  show s = "Strategy()"

doNothing :: Strategy
doNothing cd = id

data Character = Character {
  _position :: Position,
  _movement :: Movement,
  _changeDirection :: Strategy
} deriving Show

data ContextData = ContextData {
  _player :: Character,
  _dashboardSize :: DashBoardSize,
  _dashboard :: Board,
  _ghosts :: Ghosts
} deriving Show

makeLenses ''Character
makeLenses ''ContextData

type PacmanT = StateT ContextData
type PacmanEvent = PacmanT (EventM NameData)

onCD :: Monad m => (ContextData -> m b) -> PacmanT m b
onCD f = get >>= lift . f

emptyContextData :: ContextData
emptyContextData = ContextData (Character (0, 0) Stop doNothing) (0, 0) M.empty []

positionX :: Lens' Character Column
positionX = position . _2

positionY :: Lens' Character Row
positionY = position . _1

width :: Lens' ContextData Width
width = dashboardSize . _1

height :: Lens' ContextData Height
height = dashboardSize . _2

cell :: Position -> Lens' ContextData (Maybe BoardCell)
cell p = dashboard . at p

type CharacterL = Lens' ContextData Character

maze :: [String]
maze = [
  "+----------+",
  "| C        |",
  "| --+      |",
  "|   +----- |",
  "|          |",
  "| ------   |",
  "|     M    |",
  "|   ---    |",
  "|  M       |",
  "+----------+"]

parseCell :: Char -> BoardCell
parseCell ' ' = Space
parseCell 'C' = Pacman
parseCell 'M' = Ghost
parseCell _ = Brick

parseRow :: (Row, String) -> ContextData -> ContextData
parseRow (row, line) board = foldr f board $ zip [0..] line
  where f (col, c) = case parseCell c of
                          Pacman -> set (player . position) (row, col) .
                                    set (cell (row, col)) (Just Space)
                          Ghost  -> over ghosts (Character (row, col) MoveRight doNothing :) .
                                    set (cell (row, col)) (Just Space)
                          x      -> set (cell (row, col)) (Just x)

parseBoard :: [String] -> ContextData
parseBoard rows = set width (length $ head rows)
  . set height (length rows)
  . foldr parseRow emptyContextData
  $ zip [0..] rows

drawBoard :: ContextData -> Widget NameData
drawBoard cd = border $ vBox rows
  where rows = map (str . cellsInRow) [0 .. cd ^. height - 1]
        cellsInRow row = map (cellToChar . (row,)) [0 .. cd ^. width - 1]
        cellToChar pos
          | pos == cd ^. player . position = 'C'
          | cd ^. cell pos == Just Brick = '+'
          | any ((== pos) . view position) (cd ^. ghosts) = 'M'
          | otherwise = ' '

ui :: ContextData -> Widget NameData
ui cd = withBorderStyle unicode $ drawBoard cd

handleDraw :: ContextData -> [Widget NameData]
handleDraw s = [ui s]

safeDecrease :: Int -> Int
safeDecrease n
  | n > 0 = n - 1
  | otherwise = 0

safeIncrease :: Int -> Int -> Int
safeIncrease limit n
  | n < limit - 1 = n + 1
  | otherwise = limit - 1

canRotate = undefined

safeMove :: Monad m => Character -> PacmanT m Character
safeMove ch = do
  c <- use $ cell p
  case c of
    Just Space -> do
                    let ch' = ch & position .~ p
                    r <- canRotate p (ch' ^. movement)
                    if r then do
                      cd <- get
                      return $ (ch' ^. changeDirection) cd ch'
                    else
                      return ch'
    _ -> return $ ch & movement .~ Stop
  where p = (case ch ^. movement of
              MoveUp -> up
              MoveDown -> down
              MoveLeft -> left
              MoveRight -> right
              Stop -> id) $ ch ^. position

-- (<==) :: MonadState s m => ASetter s s a b -> (a -> m b) -> m ()
-- a <== f = _ a f

processTick :: Monad m => PacmanT m ()
processTick = do
  player <~ (use player >>= safeMove)
  gs <- use ghosts
  ghosts <~ mapM safeMove gs

evalPacman :: Monad m => PacmanT m a -> ContextData -> m a
evalPacman = evalStateT

movePacman :: Monad m => Movement -> PacmanT m ()
movePacman = assign $ player . movement

handleArrowKey :: Movement -> PacmanEvent (Next ContextData)
handleArrowKey m = do
  movePacman m
  onCD continue

arrows = M.fromList [(KUp, MoveUp), (KDown, MoveDown), (KLeft, MoveLeft), (KRight, MoveRight)]
handleEvent :: BrickEvent NameData EventData -> PacmanEvent (Next ContextData)
handleEvent (AppEvent Tick) = do
  processTick
  onCD continue
handleEvent (VtyEvent (EvKey (KChar 'c') [MCtrl])) = onCD halt
handleEvent (VtyEvent (EvKey k [])) | k `M.member` arrows = handleArrowKey $ arrows M.! k
handleEvent _  = onCD continue


handleStartEvent :: ContextData -> EventM NameData ContextData
handleStartEvent = return

handleAttrMap :: ContextData -> AttrMap
handleAttrMap s = attrMap defAttr []

main :: IO ()
main = do
  chan <- newBChan 10
  forkIO $ forever $ do
    writeBChan chan Tick
    threadDelay 500000
  let app = App {
        appDraw = handleDraw
        , appChooseCursor = neverShowCursor
        , appHandleEvent = flip (evalPacman . handleEvent)
        , appStartEvent = handleStartEvent
        , appAttrMap = handleAttrMap
      }
      initialState = parseBoard maze
  vty <- V.mkVty V.defaultConfig
  finalState <- customMain vty (V.mkVty V.defaultConfig) (Just chan) app initialState
  return ()
